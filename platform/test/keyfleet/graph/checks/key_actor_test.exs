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

  @fleet "fleet_tech_classic"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()

    for fleet <- Fleets.catalog_ids() do
      ChainHelpers.seed_cursor!(fleet)
      ChainHelpers.deploy!(fleet)
    end

    :ok
  end

  test "a check with no time left reads nothing and answers that it ran out" do
    sell(@fleet, 1..2)

    assert {:error, %CheckExpiredError{fleet_id: @fleet}} =
             KeyActor.command(owner(1), @fleet, 1, "c-1", 0)
  end

  # Checking a person with three million wallets takes longer than the whole
  # budget, which is spent before the key's edits are read.
  # The check that runs out comes last: a read that runs out of time takes the
  # test's sandboxed database connection with it.
  @tag :capture_log
  test "a budget spent partway through stops the check there" do
    sell(@fleet, 1..2)
    others = List.duplicate("0x" <> String.duplicate("7", 40), 3_000_000)
    slow = %Actors.Human{human_account_id: 1, wallet_addresses: others ++ [wallet(1)]}

    assert {:ok, %{auth: %{kind: "human"}}} = KeyActor.command(slow, @fleet, 1, "c-1", 1_000)

    assert {:error, _ran_out} = KeyActor.command(slow, @fleet, 1, "c-2", 5)
  end

  # Each read gets what is left of the budget as the database's own time
  # limit, and none starts once it is spent, so a millisecond runs out at one
  # or the other; either way the write is answered as unavailable. Checking a
  # person with three million wallets alone takes longer than the millisecond,
  # so the check can never finish in time.
  @tag :capture_log
  test "a one millisecond check runs out rather than answering late" do
    sell(@fleet, 1..2)
    others = List.duplicate("0x" <> String.duplicate("7", 40), 3_000_000)
    slow = %Actors.Human{human_account_id: 1, wallet_addresses: others ++ [wallet(1)]}

    assert {:error, _ran_out} = KeyActor.command(slow, @fleet, 1, "c-1", 1)
  end

  test "while the fleet's key ownership is not fresh, nobody writes" do
    sell(@fleet, 1..10)
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))

    assert {:error, %OwnershipRefreshingError{}} =
             KeyActor.command(owner(1), @fleet, 1, "c-1", 1_000)
  end

  # Widens who writes a fleet's workspace: a paired agent holding nothing in
  # the fleet is its person's Key, stamped as itself, and only while the
  # person holds that Key.
  test "a paired agent with no Key or shard here acts as its person's Key, while they hold it" do
    fleet = "fleet_tech_classic"
    sell(fleet, 1..2)
    helper = agent("9")

    assert {:error, %NotKeyHolderError{}} = KeyActor.command(helper, fleet, 1, "c-1", 1_000)
    assert KeyActor.member(helper, fleet, 1_000) == {:ok, false}

    paired = Keyfleet.PairingHelpers.pair!(helper, owner(1).wallet_addresses)

    assert {:ok, %{auth: %{kind: "agent", operator_wallet: operator}, principal: principal}} =
             KeyActor.command(paired, fleet, 1, "c-1", 1_000)

    assert operator == helper.wallet_address
    assert String.ends_with?(principal, "@1/agent:#{helper.wallet_address}")
    assert KeyActor.member(paired, fleet, 1_000) == {:ok, true}
    assert {:error, %NotKeyHolderError{}} = KeyActor.command(paired, fleet, 2, "c-1", 1_000)

    transfer(fleet, 1)

    assert {:error, %NotKeyHolderError{}} = KeyActor.command(paired, fleet, 1, "c-1", 1_000)
    assert KeyActor.member(paired, fleet, 1_000) == {:ok, false}
  end

  test "a paired agent holding a shard in the fleet acts as that shard, never as its person" do
    fleet = "fleet_tech_classic"
    sell(fleet, 1..2)
    paired = Keyfleet.PairingHelpers.pair!(agent("9"), owner(1).wallet_addresses)
    ChainHelpers.issue_shard!(fleet, 2, paired.wallet_address)

    assert {:ok, _command} = KeyActor.command(paired, fleet, 2, "c-1", 1_000)
    assert {:error, %NotKeyHolderError{}} = KeyActor.command(paired, fleet, 1, "c-1", 1_000)
  end

  # The Keys an agent is offered to act as are the ones its writes are let
  # through as: a wallet holding a Key of its own acts as that alone.
  test "an agent whose own wallet holds a Key acts as that Key alone, in what it is offered and what it writes" do
    fleet = "fleet_tech_classic"
    sell(fleet, 1..2)
    paired = Keyfleet.PairingHelpers.pair!(agent("9"), owner(1).wallet_addresses)
    record!(fleet, 3, paired.wallet_address)
    ChainHelpers.issue_shard!(fleet, 2, paired.wallet_address)

    assert Enum.map(Keys.held_keys(paired, fleet), & &1.token_id) == [3]
    assert {:ok, _command} = KeyActor.command(paired, fleet, 3, "c-1", 1_000)

    for token_id <- [1, 2] do
      assert {:error, %NotKeyHolderError{}} =
               KeyActor.command(paired, fleet, token_id, "c-1", 1_000)
    end
  end

  defp agent(character),
    do: %Actors.Agent{
      wallet_address: "0x" <> String.duplicate(character, 40),
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

  defp owner(token_id),
    do: %Actors.Human{human_account_id: token_id, wallet_addresses: [wallet(token_id)]}

  defp wallet(token_id), do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  defp sell(fleet, token_ids) do
    for token_id <- token_ids, do: record!(fleet, token_id, wallet(token_id))
  end

  defp record!(fleet, token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp transfer(fleet, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: 2,
        owner_wallet: "0x" <> String.duplicate("7", 40),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}/2"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end
