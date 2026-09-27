defmodule Keyfleet.ProposalsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Chain
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
    @now ~U[2026-09-23 12:00:00.000000Z]
    @closed DateTime.add(@now, -60)

    test "a proposal is open for votes until it closes, even with every key for it" do
      open = proposal(closes_at: DateTime.add(@now, 1), yes_keys: 7)

      assert Proposals.status(open, read_through(@now), @now) == :voting
      assert Proposals.status(%{open | closes_at: @now}, read_through(@now), @now) == :passed
    end

    test "a closed proposal is counted only once the reading has passed its closing time" do
      closed = proposal(yes_keys: 7)

      assert Proposals.status(closed, nil, @now) == :counting
      assert Proposals.status(closed, read_through(nil), @now) == :counting

      assert Proposals.status(closed, read_through(DateTime.add(@closed, -1)), @now) ==
               :counting

      assert Proposals.status(closed, read_through(@closed), @now) == :passed
    end

    test "more than half of every key that could vote must vote yes" do
      cursor = read_through(@now)

      assert Proposals.status(proposal(eligible_keys: 6, yes_keys: 4), cursor, @now) == :passed
      assert Proposals.status(proposal(eligible_keys: 6, yes_keys: 3), cursor, @now) == :failed

      # Three yes and nobody against, of seven: the four that stayed silent count against.
      assert Proposals.status(proposal(eligible_keys: 7, yes_keys: 3), cursor, @now) == :failed
      assert Proposals.status(proposal(eligible_keys: 0, yes_keys: 0), cursor, @now) == :failed
    end

    test "a passed payment expires after its last day to be paid, and a carried out one never does" do
      cursor = read_through(@now)
      last_second = Decimal.new(DateTime.to_unix(@now))
      pay = proposal(kind: :pay, yes_keys: 7, execution_expiry: last_second)

      assert Proposals.status(pay, cursor, @now) == :passed
      assert Proposals.status(pay, cursor, DateTime.add(@now, 1)) == :expired
      assert Proposals.status(%{pay | yes_keys: 1}, cursor, DateTime.add(@now, 1)) == :failed

      assert Proposals.status(%{pay | execution: %Execution{}}, cursor, DateTime.add(@now, 1)) ==
               :executed
    end

    # The fleet contract refuses a launch after its last second, and any
    # launch once one has gone ahead, which it checks first.
    test "a passed launch expires after its last second, and closes once another launch goes ahead" do
      cursor = read_through(@now)
      last_second = Decimal.new(DateTime.to_unix(@now))
      launch = proposal(kind: :autolaunch, yes_keys: 7, execution_expiry: last_second)
      later = DateTime.add(@now, 1)

      assert Proposals.status(launch, cursor, @now) == :passed
      assert Proposals.status(launch, cursor, later) == :expired

      launched = %{launch | fleet_launched?: true}
      assert Proposals.status(launched, cursor, @now) == :closed
      assert Proposals.status(launched, cursor, later) == :closed

      # Only a passed launch closes: one still open or failed says so, a
      # decision or payment is unaffected, and the one that went ahead is it.
      assert Proposals.status(%{launched | closes_at: later}, cursor, @now) == :voting
      assert Proposals.status(%{launched | yes_keys: 1}, cursor, @now) == :failed

      assert Proposals.status(%{launched | kind: :pay}, cursor, later) == :expired
      assert Proposals.status(%{launched | kind: :decision}, cursor, later) == :passed
      assert Proposals.status(%{launched | execution: %Execution{}}, cursor, later) == :executed
    end

    test "a carried out proposal is shown as carried out, whatever the reading says" do
      executed = proposal(execution: %Execution{}, closes_at: DateTime.add(@now, 60))
      assert Proposals.status(executed, nil, @now) == :executed
    end

    defp proposal(fields) do
      struct!(
        %Proposal{
          kind: :decision,
          closes_at: @closed,
          eligible_keys: 7,
          yes_keys: 0,
          no_keys: 0,
          execution: nil,
          fleet_launched?: false
        },
        fields
      )
    end

    defp read_through(at), do: %{read_through_at: at}
  end

  describe "changes" do
    test "each record after the one asked for is read once, in the order the reader numbered it" do
      assert Proposals.changes(@fleet, 0, DateTime.utc_now()) ==
               %{items: [], next_cursor: 0, head_seq: 0, has_more: false}

      for number <- 1..3, do: ProposalHelpers.proposal!(@fleet, number)
      ProposalHelpers.vote!(@fleet, 1, @owner, true, [1, 2])
      income_receipt!()

      changes = Proposals.changes(@fleet, 0, DateTime.utc_now())

      assert Enum.map(changes.items, &{&1.proposal.number, &1.changed_seq, &1.status}) ==
               [{2, 2, :voting}, {3, 3, :voting}, {1, 4, :voting}]

      assert List.last(changes.items).proposal.yes_keys == 2
      # The income is numbered with the rest but changes no proposal.
      assert {changes.next_cursor, changes.head_seq, changes.has_more} == {5, 5, false}

      assert Proposals.changes(@fleet, 5, DateTime.utc_now()) ==
               %{items: [], next_cursor: 5, head_seq: 5, has_more: false}

      assert Enum.map(Proposals.changes(@fleet, 3, DateTime.utc_now()).items, & &1.changed_seq) ==
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

      first = Proposals.changes(@fleet, 0, DateTime.utc_now())
      assert :atomics.get(saved, 1) == 1
      assert Enum.map(first.items, &{&1.proposal.number, &1.changed_seq}) == [{1, 1}]
      assert {first.next_cursor, first.head_seq, first.has_more} == {1, 1, false}

      rest = Proposals.changes(@fleet, first.next_cursor, DateTime.utc_now())
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
    ProposalHelpers.proposal!(@fleet, 5, closes_at: DateTime.add(DateTime.utc_now(), -60))
    ProposalHelpers.execution!(@fleet, 5, @owner)

    past = DateTime.add(DateTime.utc_now(), -3600)

    for number <- 6..8 do
      ProposalHelpers.proposal!(@fleet, number,
        kind: :autolaunch,
        closes_at: past,
        eligible_keys: 1,
        execution_expiry: Decimal.new(DateTime.to_unix(past) + 60)
      )

      ProposalHelpers.vote!(@fleet, number, @owner, true, [1])
    end

    {:ok, _} =
      Chain.advance_cursor(Chain.get_cursor!(@fleet), %{read_through_at: DateTime.utc_now()})

    %{items: expired} = Proposals.changes(@fleet, 0, DateTime.utc_now())
    assert %{status: :expired} = Enum.find(expired, &(&1.proposal.number == 6))

    assert json(ProposalJSON.summary(Enum.find(expired, &(&1.proposal.number == 6))))["status"] ==
             "expired"

    ProposalHelpers.execution!(@fleet, 8, @owner)

    %{items: items} = Proposals.changes(@fleet, 0, DateTime.utc_now())
    assert length(items) == 8

    for item <- items do
      summary = json(ProposalJSON.summary(item))
      detail = json(ProposalJSON.detail(item.proposal, item.status))
      assert ContractSchema.errors(summary, "ProposalSummary") == [], inspect(summary)
      assert ContractSchema.errors(detail, "ProposalDetail") == [], inspect(detail)
    end

    by_number = Map.new(items, &{&1.proposal.number, &1})
    assert json(ProposalJSON.summary(by_number[1]))["text_preview"] == "Ship �"

    assert %{"asset" => _, "amount" => "5000000", "recipient" => _, "execution_expiry" => _} =
             json(ProposalJSON.summary(by_number[2]))["pay"]

    assert json(ProposalJSON.summary(by_number[3]))["launch"]["envelope"] == nil

    assert %{"name" => "Cascade �", "required_regent_raised" => "250000000000000000000000"} =
             json(ProposalJSON.summary(by_number[4]))["launch"]["envelope"]

    assert %{"status" => "executed", "executed" => %{"executor" => @owner}} =
             json(ProposalJSON.summary(by_number[5]))

    assert json(ProposalJSON.summary(by_number[6]))["status"] == "closed"

    assert json(ProposalJSON.detail(by_number[7].proposal, by_number[7].status))["status"] ==
             "closed"

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
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end
