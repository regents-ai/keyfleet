defmodule Keyfleet.GraphTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @contract "0x" <> String.duplicate("7", 40)
  @owner "0x" <> String.duplicate("a", 40)
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

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        asset_registry_address: "0x" <> String.duplicate("4", 40),
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )

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

  test "a key's owner writes as that key, and the log records a person with no pairing or credential" do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

    assert {:ok, %{result: %{"id" => "note#1", "version" => 1}, replayed: false}} =
             Graph.create_object(@fleet, Map.merge(@note, %{as_key: 1, command_id: "h-1"}),
               actor: owner
             )

    assert {:ok, %{events: events}} = Graph.list_changes(@fleet, %{}, actor: nil)
    [command] = for %{type: "keyfleet.command"} = event <- events, do: event
    assert command.payload["principal"] == "member:8453:#{@contract}:1@1/human:#{@owner}"

    {:ok, %{"result" => %{"events" => logged}}} =
      Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    [stamped] = for %{"type" => "keyfleet.command"} = event <- logged, do: event

    assert %{"kind" => "human", "pairing_id" => nil, "credential_ref" => nil} =
             stamped["payload"]["auth"]
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

    assert {:ok, %{events: events}} = Graph.list_changes(@fleet, %{}, actor: nil)
    refute Enum.any?(events, &(&1.type == "keyfleet.command"))
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
