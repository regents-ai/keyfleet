defmodule Keyfleet.ProposalsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.{Execution, Proposal}
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Treasury
  alias KeyfleetWeb.ProposalJSON

  @fleet "fibonacci_syndicate"
  @owner ProposalHelpers.wallet("a")

  setup do
    # Syncs read the workspace in a repeatable-read snapshot, which Postgres
    # allows inside the sandbox only when its transaction is at that level already.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    :ok
  end

  describe "status" do
    test "a proposal is approved once more than half of all the keys sold vote yes" do
      assert Proposals.status(proposal(keys_sold: 6, yes_keys: 4), nil) == :approved
      assert Proposals.status(proposal(keys_sold: 6, yes_keys: 3), nil) == :open

      # Three yes and nobody against, of seven: the four that stayed silent count against.
      assert Proposals.status(proposal(keys_sold: 7, yes_keys: 3), nil) == :open
      assert Proposals.status(proposal(keys_sold: 0, yes_keys: 0), nil) == :open
    end

    test "a carried out proposal is shown as carried out, whatever its votes" do
      assert Proposals.status(proposal(keys_sold: 7, yes_keys: 0, execution: %Execution{}), nil) ==
               :executed
    end

    test "a key's latest vote is the one that counts" do
      ProposalHelpers.proposal!(@fleet, 1)
      for token_id <- 1..3, do: owner_of_key!(token_id)

      ProposalHelpers.vote!(@fleet, 1, @owner, true, [1, 2])
      ProposalHelpers.vote!(@fleet, 1, @owner, false, [2, 3])

      assert %{yes_keys: 1, no_keys: 2, keys_sold: 3} = Proposals.get_by_number(@fleet, 1)

      ProposalHelpers.vote!(@fleet, 1, @owner, true, [2, 3])
      voted = Proposals.get_by_number(@fleet, 1)
      assert {voted.yes_keys, voted.no_keys} == {3, 0}
      assert Proposals.status(voted, nil) == :approved
    end

    test "a key sold after a proposal was approved counts against it until it votes" do
      ProposalHelpers.proposal!(@fleet, 1)
      for token_id <- 1..3, do: owner_of_key!(token_id)
      ProposalHelpers.vote!(@fleet, 1, @owner, true, [1, 2])

      assert Proposals.status(Proposals.get_by_number(@fleet, 1), nil) == :approved

      owner_of_key!(4)
      assert %{keys_sold: 4} = sold = Proposals.get_by_number(@fleet, 1)
      assert Proposals.status(sold, nil) == :open
    end

    # The fleet refuses a launch proposal that opened in or before the block
    # its last failed launch was created in; only launches are affected.
    test "a launch proposed before the last failed launch is stale, and one after it is not" do
      stale = proposal(kind: :autolaunch, opened_block: 10, keys_sold: 1, yes_keys: 1)
      assert Proposals.status(stale, 10) == :stale
      assert Proposals.status(stale, 9) == :approved
      assert Proposals.status(stale, nil) == :approved
      assert Proposals.status(%{stale | execution: %Execution{}}, 10) == :executed
      assert Proposals.status(%{stale | kind: :decision}, 10) == :approved
    end

    test "the failed launch block is the one the fleet's latest reading names" do
      assert Proposals.failed_launch_block(@fleet) == nil
      ProposalHelpers.treasury_reading!(@fleet, [], failed_launch_block: 10)
      assert Proposals.failed_launch_block(@fleet) == 10
    end

    defp proposal(fields) do
      struct!(%Proposal{kind: :decision, no_keys: 0, execution: nil}, fields)
    end
  end

  describe "changes" do
    test "a launch proposed before the fleet's last failed launch is read as stale" do
      ProposalHelpers.proposal!(@fleet, 1, kind: :autolaunch, opened_block: 10)
      ProposalHelpers.proposal!(@fleet, 2, kind: :autolaunch, opened_block: 11)
      ProposalHelpers.treasury_reading!(@fleet, [], failed_launch_block: 10)

      assert Enum.map(Proposals.changes(@fleet, 0).items, &{&1.proposal.number, &1.status}) ==
               [{1, :stale}, {2, :open}]
    end

    test "each record after the one asked for is read once, in the order the reader numbered it" do
      assert Proposals.changes(@fleet, 0) ==
               %{items: [], next_cursor: 0, head_seq: 0, has_more: false}

      for number <- 1..3, do: ProposalHelpers.proposal!(@fleet, number)
      for token_id <- 1..5, do: owner_of_key!(token_id)
      ProposalHelpers.vote!(@fleet, 1, @owner, true, [1, 2])
      income_receipt!()

      changes = Proposals.changes(@fleet, 0)

      assert Enum.map(changes.items, &{&1.proposal.number, &1.changed_seq, &1.status}) ==
               [{2, 2, :open}, {3, 3, :open}, {1, 4, :open}]

      assert List.last(changes.items).proposal.yes_keys == 2
      # The income is numbered with the rest but changes no proposal.
      assert {changes.next_cursor, changes.head_seq, changes.has_more} == {5, 5, false}

      assert Proposals.changes(@fleet, 5) ==
               %{items: [], next_cursor: 5, head_seq: 5, has_more: false}

      assert Enum.map(Proposals.changes(@fleet, 3).items, & &1.changed_seq) ==
               [4]
    end

    test "a record saved while the changes are being read is left for the next read" do
      ProposalHelpers.proposal!(@fleet, 1)
      test_pid = self()
      saved = :atomics.new(1, [])

      # Right after the proposals are read, a new proposal and then income
      # are saved: the income is numbered after the proposal the read
      # has missed, and touches no proposal of its own.
      :telemetry.attach(
        "saved-while-reading-changes",
        [:keyfleet, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid and meta.source == "proposals" and
               :atomics.compare_exchange(saved, 1, 0, 1) == :ok do
            ProposalHelpers.proposal!(@fleet, 2)
            ProposalHelpers.income_receipt!(@fleet)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("saved-while-reading-changes") end)

      first = Proposals.changes(@fleet, 0)
      assert :atomics.get(saved, 1) == 1
      assert Enum.map(first.items, &{&1.proposal.number, &1.changed_seq}) == [{1, 1}]
      assert {first.next_cursor, first.head_seq, first.has_more} == {1, 1, false}

      rest = Proposals.changes(@fleet, first.next_cursor)
      assert Enum.map(rest.items, &{&1.proposal.number, &1.changed_seq}) == [{2, 2}]
      assert {rest.next_cursor, rest.head_seq} == {3, 3}
    end

    test "a catch-up from the start comes fifty records at a time and asks to come straight back" do
      for number <- 1..55, do: ProposalHelpers.proposal!(@fleet, number)
      owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
      owner_of_key!(1)

      {:ok, first} = Rooms.sync(@fleet, [], 0, 0, owner)
      assert Enum.map(first.proposals.items, & &1.proposal.number) == Enum.to_list(1..50)
      assert {first.proposals.next_cursor, first.proposals.has_more} == {50, true}
      assert first.next_poll_seconds == 0

      {:ok, again} = Rooms.sync(@fleet, [], 0, 0, owner)
      assert again.proposals == first.proposals

      {:ok, rest} = Rooms.sync(@fleet, [], 0, 50, owner)
      assert Enum.map(rest.proposals.items, & &1.proposal.number) == Enum.to_list(51..55)
      assert {rest.proposals.next_cursor, rest.proposals.has_more} == {55, false}
      assert rest.next_poll_seconds > 0
    end
  end

  test "each kind of proposal is answered as the contract describes it" do
    ProposalHelpers.proposal!(@fleet, 1, text: <<"Ship ", 0xFF>>, text_bytes: 6)
    ProposalHelpers.proposal!(@fleet, 2, kind: :pay)
    ProposalHelpers.proposal!(@fleet, 3, kind: :autolaunch)
    launched = ProposalHelpers.proposal!(@fleet, 4, kind: :autolaunch)
    ProposalHelpers.launch_envelope!(launched, name: <<"Cascade ", 0xFE>>)
    ProposalHelpers.proposal!(@fleet, 5)
    ProposalHelpers.execution!(@fleet, 5, @owner)
    owner_of_key!(1)

    for number <- 6..8 do
      ProposalHelpers.proposal!(@fleet, number, kind: :autolaunch)
      ProposalHelpers.vote!(@fleet, number, @owner, true, [1])
    end

    ProposalHelpers.execution!(@fleet, 8, @owner)

    %{items: items} = Proposals.changes(@fleet, 0)
    assert length(items) == 8

    for item <- items do
      summary = json(ProposalJSON.summary(item))
      detail = json(ProposalJSON.detail(item.proposal, item.status))
      assert ContractSchema.errors(summary, "ProposalSummary") == [], inspect(summary)
      assert ContractSchema.errors(detail, "ProposalDetail") == [], inspect(detail)
    end

    by_number = Map.new(items, &{&1.proposal.number, &1})
    assert json(ProposalJSON.summary(by_number[1]))["text_preview"] == "Ship �"

    assert %{"asset" => _, "amount" => "5000000", "recipient" => _} =
             json(ProposalJSON.summary(by_number[2]))["pay"]

    assert json(ProposalJSON.summary(by_number[3]))["launch"]["envelope"] == nil

    assert %{
             "name" => "Cascade �",
             "floor_price_q96" => "79228162514264337593500",
             "minimum_regent_raised" => "0",
             "required_regent_raised" => "19999999999999999999989"
           } = json(ProposalJSON.summary(by_number[4]))["launch"]["envelope"]

    assert %{"status" => "executed", "executed" => %{"executor" => @owner}} =
             json(ProposalJSON.summary(by_number[5]))

    assert %{"status" => "approved", "yes_votes" => 1, "keys_sold" => 1} =
             json(ProposalJSON.summary(by_number[6]))

    assert json(ProposalJSON.detail(by_number[7].proposal, by_number[7].status))["status"] ==
             "approved"

    assert json(ProposalJSON.summary(by_number[8]))["status"] == "executed"
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp income_receipt! do
    Treasury.record_income_receipt!(
      %{
        fleet_id: @fleet,
        asset: ProposalHelpers.wallet("c"),
        caller: @owner,
        amount: Decimal.new(10),
        block_number: 900,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("9", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp owner_of_key!(token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: token_id
      },
      actor: %Actors.System{}
    )
  end
end
