defmodule Keyfleet.GraphTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.EditsRestrictedError
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @contract "0x" <> String.duplicate("7", 40)
  @owner "0x" <> String.duplicate("a", 40)
  @agent %Actors.Agent{
    wallet_address: "0x" <> String.duplicate("c", 40),
    chain_id: 8453,
    verification_method: :eoa_recovery,
    audience: "keyfleet"
  }
  @holder %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
  @note %{type: "note", scope: "fleet", data: %{title: "Plan", body: "Ship the first service."}}

  setup %{tmp_dir: tmp_dir} do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    ChainHelpers.deploy!(@fleet, %{manager_address: @contract})

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    start_supervised!(
      {Keyfleet.Graph.Supervisor,
       fleets: [@fleet],
       data_dir: Path.join(tmp_dir, "graph"),
       reply_timeout: 5_000,
       hello_timeout: 30_000,
       restart_min: 20,
       restart_max: 200}
    )

    await_ready()
    start_supervised!({Keyfleet.Graph.Projectors, fleets: [@fleet]})
    :ok
  end

  test "a key's owner writes as that key, and the log records a person with no credential" do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

    assert {:ok, %{result: %{"id" => "note#1", "version" => 1}, replayed: false}} =
             Graph.create_object(@fleet, Map.merge(@note, %{as_key: 1, command_id: "h-1"}),
               actor: owner
             )

    assert {:ok, %{events: events}} = Graph.list_changes(@fleet, %{}, actor: @holder)
    [command] = for %{type: "keyfleet.command"} = event <- events, do: event
    assert command.payload["principal"] == "member:8453:#{@contract}:1@1/human:#{@owner}"

    {:ok, %{"result" => %{"events" => logged}}} =
      Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    [stamped] = for %{"type" => "keyfleet.command"} = event <- logged, do: event

    assert %{"kind" => "human", "credential_ref" => nil} = stamped["payload"]["auth"]
  end

  test "a person who holds none of the fleet's keys is refused before anything is written" do
    stranger = %Actors.Human{
      human_account_id: 2,
      wallet_addresses: ["0x" <> String.duplicate("b", 40)]
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Graph.create_object(@fleet, Map.merge(@note, %{as_key: 1, command_id: "h-1"}),
               actor: stranger
             )

    assert {:ok, %{events: events}} = Graph.list_changes(@fleet, %{}, actor: @holder)
    refute Enum.any?(events, &(&1.type == "keyfleet.command"))
  end

  test "only a wallet that owns one of the fleet's Keys, or holds a shard of one, reads the workspace" do
    {:ok, _written} = write(@holder, 1, "w-1")

    stranger = %Actors.Human{
      human_account_id: 2,
      wallet_addresses: ["0x" <> String.duplicate("b", 40)]
    }

    reads = fn actor ->
      {Graph.get_object(@fleet, "note#1", actor: actor),
       Graph.list_changes(@fleet, %{}, actor: actor)}
    end

    for actor <- [nil, stranger, @agent] do
      assert {{:error, %Ash.Error.Forbidden{}}, {:error, %Ash.Error.Forbidden{}}} = reads.(actor)
    end

    ChainHelpers.issue_shard!(@fleet, 1, @agent.wallet_address)

    for actor <- [@holder, @agent] do
      assert {{:ok, %{object: %{id: "note#1"}}}, {:ok, %{events: [_ | _]}}} = reads.(actor)
    end

    # Ownership being read again grants nothing, a Key's owner included.
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    assert {{:error, %Ash.Error.Forbidden{}}, {:error, %Ash.Error.Forbidden{}}} = reads.(@holder)
  end

  test "an agent with a shard writes as the key, and only as that key" do
    ChainHelpers.issue_shard!(@fleet, 1, @agent.wallet_address)

    assert {:ok, %{result: %{"id" => "note#1"}}} = write(@agent, 1, "s-1")
    assert principal("s-1") == "member:8453:#{@contract}:1@1/agent:#{@agent.wallet_address}"

    # Another key, a wallet with no shard, and the shard once its owner ends it.
    epoch!(2, @owner)
    assert {:error, %Ash.Error.Forbidden{}} = write(@agent, 2, "s-2")

    assert {:error, %Ash.Error.Forbidden{}} =
             write(%{@agent | wallet_address: "0x" <> String.duplicate("d", 40)}, 1, "s-3")

    ChainHelpers.end_shard!(@fleet, 1, @agent.wallet_address, @owner)
    assert {:error, %Ash.Error.Forbidden{}} = write(@agent, 1, "s-4")
  end

  test "a wallet that owns a key writes as its own key, never as a shard" do
    epoch!(2, @agent.wallet_address)
    ChainHelpers.issue_shard!(@fleet, 1, @agent.wallet_address)

    assert {:error, %Ash.Error.Forbidden{}} = write(@agent, 1, "o-1")
    assert {:ok, _written} = write(@agent, 2, "o-2")
    assert principal("o-2") == "member:8453:#{@contract}:2@1/agent:#{@agent.wallet_address}"
  end

  test "while a vote has restricted a key's edits, neither its owner nor its shard writes" do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    ChainHelpers.issue_shard!(@fleet, 1, @agent.wallet_address)
    restrict!(1, true, 1)

    for {actor, id} <- [{owner, "r-1"}, {@agent, "r-2"}] do
      assert {:error, %Ash.Error.Forbidden{errors: [%EditsRestrictedError{token_id: 1}]}} =
               write(actor, 1, id)
    end

    assert {:ok, %{events: events}} = Graph.list_changes(@fleet, %{}, actor: @holder)
    refute Enum.any?(events, &(&1.type == "keyfleet.command"))

    restrict!(1, false, 2)
    assert {:ok, _written} = write(owner, 1, "r-3")
    assert {:ok, _written} = write(@agent, 1, "r-4")
  end

  defp write(actor, token_id, command_id),
    do:
      Graph.create_object(@fleet, Map.merge(@note, %{as_key: token_id, command_id: command_id}),
        actor: actor
      )

  # The principal the command `command_id` was recorded under.
  defp principal(command_id) do
    {:ok, %{"result" => %{"events" => logged}}} =
      Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    Enum.find_value(logged, fn
      %{"type" => "keyfleet.command", "payload" => %{"command_id" => ^command_id} = payload} ->
        payload["principal"]

      _event ->
        nil
    end)
  end

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate(Integer.to_string(token_id), 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # The key's edits restricted or allowed, as the `number`th setting on the chain.
  defp restrict!(token_id, restricted, number) do
    Keys.record_edits_restriction!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        restricted: restricted,
        block_number: 20 + number,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("e#{number}", 32),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp await_ready(attempts \\ 750) do
    case Writer.request(@fleet, "hello", %{}) do
      {:ok, _hello} ->
        :ok

      {:error, _reason} when attempts > 0 ->
        Process.sleep(20)
        await_ready(attempts - 1)
    end
  end
end
