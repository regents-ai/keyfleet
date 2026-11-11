defmodule Keyfleet.ProposalsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.{Cancellation, Execution, Proposal}
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
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
    # The contract's own states (`KeyfleetVotes.status`): open until it
    # closes, then approved with more than half of the keys present when it
    # opened and the late voters voting yes, until its execution expiry.
    test "a proposal stands where the contract says it does" do
      opened = ~U[2026-10-01 00:00:00Z]
      closes = DateTime.add(opened, 86_400)
      expiry = DateTime.add(closes, 86_400)
      during = DateTime.add(opened, 60)
      after_close = DateTime.add(closes, 60)

      proposal =
        &struct!(
          %Proposal{
            closes_at: closes,
            execution_expiry: expiry,
            opening_count: 4,
            late_keys: 0,
            yes_keys: 0,
            cancellation: nil,
            execution: nil
          },
          &1
        )

      assert Proposals.status(proposal.(yes_keys: 4), during) == :open
      assert Proposals.status(proposal.(yes_keys: 3), after_close) == :approved
      # Exactly half is not enough, and a late voter raises the bar.
      assert Proposals.status(proposal.(yes_keys: 2), after_close) == :rejected
      assert Proposals.status(proposal.(yes_keys: 3, late_keys: 2), after_close) == :rejected
      assert Proposals.status(proposal.(yes_keys: 3), expiry) == :execution_expired

      assert Proposals.status(proposal.(yes_keys: 3, execution: %Execution{}), expiry) ==
               :executed

      assert Proposals.status(proposal.(cancellation: %Cancellation{}), during) == :cancelled
    end

    test "a key's latest vote is the one that counts" do
      ProposalHelpers.proposal!(@fleet, 1)

      ProposalHelpers.vote!(@fleet, 1, @owner, :yes, [1, 2])
      ProposalHelpers.vote!(@fleet, 1, @owner, :no, [2, 3])
      ProposalHelpers.vote!(@fleet, 1, @owner, :abstain, [4])

      assert %{yes_keys: 1, no_keys: 2, abstain_keys: 1} = Proposals.get_by_number(@fleet, 1)

      ProposalHelpers.vote!(@fleet, 1, @owner, :yes, [3, 2])
      voted = Proposals.get_by_number(@fleet, 1)
      assert {voted.yes_keys, voted.no_keys, voted.abstain_keys} == {3, 0, 1}
      assert Proposals.key_ballots(voted) == %{yes: [1, 2, 3], no: [], abstain: [4], silent: []}
    end

    # `KeyfleetVotes.wasActiveAtOpening`: a key voting counts toward the bar
    # only when its last presence record before the proposal is not a renewal
    # within 48 hours of the opening.
    test "a key that voted without being present when the proposal opened is a late voter" do
      opened = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      ProposalHelpers.presence!(@fleet, 1, DateTime.add(opened, -3_600))
      ProposalHelpers.presence!(@fleet, 2, DateTime.add(opened, -172_800))
      ProposalHelpers.presence!(@fleet, 3, DateTime.add(opened, -3_600))
      ProposalHelpers.presence!(@fleet, 3, nil)
      ProposalHelpers.presence!(@fleet, 6, DateTime.add(opened, -7_200))
      ProposalHelpers.proposal!(@fleet, 1, opened_at: opened, opening_count: 2)
      # Renewed after the opening: still late on this proposal.
      ProposalHelpers.presence!(@fleet, 4, opened)

      ProposalHelpers.vote!(@fleet, 1, @owner, :yes, [1, 2, 3, 4, 5])
      ProposalHelpers.vote!(@fleet, 1, @owner, :no, [5])

      # Key 1 was present; key 2's renewal had run out, key 3 changed hands,
      # key 4 was renewed only after and key 5 never was. Key 5 counts once.
      # Key 6 was present and has not voted.
      proposal = Proposals.get_by_number(@fleet, 1)
      assert %{late_keys: 4} = proposal

      assert Proposals.key_ballots(proposal) ==
               %{yes: [1, 2, 3, 4], no: [5], abstain: [], silent: [6]}
    end
  end

  describe "changes" do
    test "each record after the one asked for is read once, in the order the reader numbered it" do
      assert Proposals.changes(@fleet, 0) ==
               %{items: [], next_cursor: 0, head_seq: 0, has_more: false}

      for number <- 1..3, do: ProposalHelpers.proposal!(@fleet, number)
      ProposalHelpers.vote!(@fleet, 1, @owner, :yes, [1, 2])
      money_event!()

      changes = Proposals.changes(@fleet, 0)

      assert Enum.map(changes.items, &{&1.proposal.number, &1.changed_seq, &1.status}) ==
               [{2, 2, :open}, {3, 3, :open}, {1, 4, :open}]

      assert List.last(changes.items).proposal.yes_keys == 2
      # The money record is numbered with the rest but changes no proposal.
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

      # Right after the proposals are read, a new proposal and then a money
      # record are saved: the money record is numbered after the proposal the
      # read has missed, and touches no proposal of its own.
      :telemetry.attach(
        "saved-while-reading-changes",
        [:keyfleet, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid and meta.source == "proposals" and
               :atomics.compare_exchange(saved, 1, 0, 1) == :ok do
            ProposalHelpers.proposal!(@fleet, 2)
            money_event!()
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

    test "a catch-up from the start comes fifty records at a time" do
      for number <- 1..55, do: ProposalHelpers.proposal!(@fleet, number)
      owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
      owner_of_key!(1)

      {:ok, first} =
        Rooms.sync(
          @fleet,
          [],
          %{graph: 0, project: nil, proposals: 0, keys: [], dms: nil, quotes: nil},
          owner,
          false
        )

      assert Enum.map(first.proposals.items, & &1.proposal.number) == Enum.to_list(1..50)
      assert {first.proposals.next_cursor, first.proposals.has_more} == {50, true}

      {:ok, again} =
        Rooms.sync(
          @fleet,
          [],
          %{graph: 0, project: nil, proposals: 0, keys: [], dms: nil, quotes: nil},
          owner,
          false
        )

      assert again.proposals == first.proposals

      {:ok, rest} =
        Rooms.sync(
          @fleet,
          [],
          %{graph: 0, project: nil, proposals: 50, keys: [], dms: nil, quotes: nil},
          owner,
          false
        )

      assert Enum.map(rest.proposals.items, & &1.proposal.number) == Enum.to_list(51..55)
      assert {rest.proposals.next_cursor, rest.proposals.has_more} == {55, false}
    end
  end

  test "a proposal is answered as the API contract describes it, whatever its state" do
    call = %{target: ProposalHelpers.wallet("c"), value: 10 ** 30, data: "0xa9059cbb"}
    ProposalHelpers.proposal!(@fleet, 1, calls: [call, %{call | value: 0, data: "0x"}])
    ProposalHelpers.proposal!(@fleet, 2)
    ProposalHelpers.vote!(@fleet, 2, @owner, :abstain, [1])
    ProposalHelpers.execution!(@fleet, 2, @owner)
    ProposalHelpers.proposal!(@fleet, 3)
    ProposalHelpers.cancellation!(@fleet, 3, @owner)

    %{items: items} = Proposals.changes(@fleet, 0)
    assert length(items) == 3

    for item <- items do
      summary = json(ProposalJSON.summary(item))
      detail = json(ProposalJSON.detail(item.proposal, item.status))
      assert ContractSchema.errors(summary, "ProposalSummary") == [], inspect(summary)
      assert ContractSchema.errors(detail, "ProposalDetail") == [], inspect(detail)
    end

    by_number = Map.new(items, &{&1.proposal.number, json(ProposalJSON.summary(&1))})

    # Every digit of a uint256 value survives.
    assert [%{"value" => "1000000000000000000000000000000", "data" => "0xa9059cbb"}, _] =
             by_number[1]["calls"]

    assert %{"status" => "executed", "abstain_votes" => 1, "executed" => %{"executor" => @owner}} =
             by_number[2]

    assert %{"status" => "cancelled", "cancelled" => %{"cancelled_by" => @owner}} = by_number[3]
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp money_event! do
    ProposalHelpers.money_event!(@fleet, :paid,
      asset: ProposalHelpers.wallet("c"),
      account: @owner,
      share: Decimal.new(15_000),
      amount: Decimal.new(10)
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
