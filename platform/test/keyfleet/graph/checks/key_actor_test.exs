defmodule Keyfleet.Graph.Checks.KeyActorTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Errors.CheckExpiredError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError

  # Syndicate keys other suites commit outside the sandbox would count as
  # sold, so the levels are read on the Cascade fleet.
  @levelled "fibonacci_cascade"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()

    for {fleet, n} <- Enum.with_index(Fleets.catalog_ids(), 1) do
      ChainHelpers.seed_cursor!(fleet)
      deploy(fleet, "0x" <> String.duplicate("#{n}", 40))
    end

    :ok
  end

  test "a Fibonacci key writes the fleet and its own level, and each later level once all its keys are sold" do
    sell(@levelled, 1..6)

    assert scopes(@levelled, 1) == ["fleet", "level:1", "level:2"]
    assert scopes(@levelled, 3) == ["fleet", "level:2"]
    assert scopes(@levelled, 6) == ["fleet", "level:3"]

    sell(@levelled, 7..10)

    assert scopes(@levelled, 1) == ["fleet", "level:1", "level:2", "level:3"]
    assert scopes(@levelled, 3) == ["fleet", "level:2", "level:3"]
    assert scopes(@levelled, 6) == ["fleet", "level:3"]
  end

  test "a key changing hands sells nothing, so it opens no level" do
    sell(@levelled, 1..9)
    transfer(@levelled, 9)
    transfer(@levelled, 4)

    assert Keyfleet.Chain.minted(@levelled) == {:ok, 9}
    assert Keyfleet.Chain.progress(@levelled).total_minted == 9
    assert scopes(@levelled, 1) == ["fleet", "level:1", "level:2"]
  end

  test "key 1 of a sold-out fleet writes the fleet and all twenty levels" do
    sell_all!(@levelled)

    assert scopes(@levelled, 1) == ["fleet" | Enum.map(1..20, &"level:#{&1}")]
    assert scopes(@levelled, 46_365) == ["fleet", "level:20"]
  end

  test "a check with no time left reads nothing and answers that it ran out" do
    sell(@levelled, 1..2)

    assert {:error, %CheckExpiredError{fleet_id: @levelled}} =
             KeyActor.command(owner(1), @levelled, 1, "c-1", 0)
  end

  # Checking a person with three million wallets takes longer than the whole
  # budget, which is spent by the time the check would count the keys sold.
  # The check that runs out comes last: a read that runs out of time takes the
  # test's sandboxed database connection with it.
  @tag :capture_log
  test "a budget spent before the keys sold are counted stops the check there" do
    sell(@levelled, 1..2)
    others = List.duplicate("0x" <> String.duplicate("7", 40), 3_000_000)
    slow = %Actors.Human{human_account_id: 1, wallet_addresses: others ++ [wallet(1)]}

    assert {:ok, %{writable_scopes: ["fleet", "level:1"]}} =
             KeyActor.command(slow, @levelled, 1, "c-1", 1_000)

    assert {:error, _ran_out} = KeyActor.command(slow, @levelled, 1, "c-2", 5)
  end

  # Each read gets what is left of the budget as the database's own time
  # limit, and none starts once it is spent, so a millisecond runs out at one
  # or the other; either way the write is answered as unavailable.
  @tag :capture_log
  test "a one millisecond check of a sold-out fleet runs out rather than answering late" do
    sell_all!(@levelled)

    assert {:error, _ran_out} = KeyActor.command(owner(1), @levelled, 1, "c-1", 1)
  end

  test "a key number past the fleet's supply writes nothing" do
    sell(@levelled, [46_366])

    assert {:error, %NotKeyHolderError{token_id: 46_366}} =
             KeyActor.command(owner(46_366), @levelled, 46_366, "c-1", 1_000)
  end

  test "a Classic or Accelerant key writes the fleet scope only, however many keys are sold" do
    for fleet <- ["fleet_tech_classic", "fleet_tech_accelerant"] do
      sell(fleet, 1..10)
      assert scopes(fleet, 1) == ["fleet"]
      assert scopes(fleet, 10) == ["fleet"]
    end
  end

  test "while the fleet's key ownership is not fresh, no scope is granted" do
    sell(@levelled, 1..10)
    ChainHelpers.seed_cursor!(@levelled, observed_at: DateTime.add(DateTime.utc_now(), -3600))

    assert {:error, %OwnershipRefreshingError{}} =
             KeyActor.command(owner(1), @levelled, 1, "c-1", 1_000)
  end

  defp scopes(fleet, token_id) do
    {:ok, command} = KeyActor.command(owner(token_id), fleet, token_id, "c-1", 1_000)
    command.writable_scopes
  end

  defp owner(token_id),
    do: %Actors.Human{human_account_id: token_id, wallet_addresses: [wallet(token_id)]}

  defp wallet(token_id), do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  defp sell(fleet, token_ids) do
    for token_id <- token_ids do
      Keys.record_epoch!(
        %{
          fleet_id: fleet,
          token_id: token_id,
          ownership_epoch: 0,
          owner_wallet: wallet(token_id),
          block_number: 10,
          block_hash: "0x" <> String.duplicate("a", 64),
          transaction_hash:
            "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}"), case: :lower),
          log_index: 0
        },
        actor: %Actors.System{}
      )
    end
  end

  defp transfer(fleet, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: "0x" <> String.duplicate("7", 40),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}/1"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # Every key of a Fibonacci fleet, and a transfer of every tenth, written
  # straight to the table and numbered as the chain reader numbers them: one
  # at a time would take minutes.
  defp sell_all!(fleet) do
    epochs =
      for token_id <- 1..46_365,
          epoch <- if(rem(token_id, 10) == 0, do: [0, 1], else: [0]),
          do: {token_id, epoch}

    rows =
      for {{token_id, epoch}, seq} <- Enum.with_index(epochs, 1) do
        %{
          id: Ecto.UUID.bingenerate(),
          fleet_id: fleet,
          token_id: token_id,
          ownership_epoch: epoch,
          owner_wallet: wallet(token_id),
          block_number: 10 + epoch,
          block_hash: "0x" <> String.duplicate("a", 64),
          transaction_hash:
            "0x" <>
              Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}/#{epoch}"), case: :lower),
          log_index: 0,
          record_seq: seq
        }
      end

    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Keyfleet.Repo.insert_all("key_attachments", &1))

    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.chain_cursors SET ownership_seq = $2 WHERE fleet_id = $1",
      [fleet, length(rows)]
    )
  end

  defp deploy(fleet, contract) do
    fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end
end
