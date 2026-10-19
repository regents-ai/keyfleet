defmodule KeyfleetWeb.Live.PollsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Actors.Human
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Polls
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.FleetPolls

  @fleet "fibonacci_syndicate"
  @list "/syndicate/1/polls"
  @starter ProposalHelpers.wallet("1")
  @voter ProposalHelpers.wallet("2")
  @notes "The left one creaks."

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet, %{manager_address: "0x" <> String.duplicate("7", 40)})
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, [1], @starter)
    ProposalHelpers.keys_sold!(@fleet, [2], @voter)

    # The readings every page shares outlive a test's database, so each test
    # starts with none held.
    for kind <- [:fleet_polls, :poll],
        id <- SharedReading.ids(kind),
        do: SharedReading.delete({kind, id})

    :ok
  end

  # Every open page draws the fleet's next reading and reads nothing itself;
  # the time left is drawn in the browser from the poll's closing time.
  test "a vote reaches every open page of the poll with the fleet's next reading", %{
    conn: conn
  } do
    poll = start!()

    {:ok, view, _html} = open(conn, "#{@list}/#{poll.id}")
    {:ok, list, _html} = live(conn, @list)

    assert has_element?(view, "#poll-votes-so-far", "0 votes so far")
    assert has_element?(list, "#poll-#{poll.id}", "0 votes")

    closes_at = DateTime.to_unix(poll.closes_at, :millisecond)

    assert has_element?(
             view,
             ~s(#poll-left[phx-hook="PollCountdown"][data-closes-at="#{closes_at}"])
           )

    vote!(poll, @voter)
    assert has_element?(view, "#poll-votes-so-far", "0 votes so far")

    FleetPolls.read(@fleet)

    assert shows?(fn -> has_element?(view, "#poll-votes-so-far", "1 vote so far") end)
    assert shows?(fn -> has_element?(list, "#poll-#{poll.id}", "1 vote") end)
  end

  # The reading every page shares holds what anyone may read of a poll and
  # nothing more; a Key holder's page reads the notes and the votes as them.
  test "a poll's notes and each Key's vote are read only for a Key holder", %{conn: conn} do
    poll = start!()
    vote!(poll, @voter)

    {:ok, visitor, html} = open(conn, "#{@list}/#{poll.id}")
    refute html =~ @notes
    refute has_element?(visitor, "#poll-notes")

    {reading, false} = FleetPolls.fetch(FleetPolls.poll_key(@fleet, poll.id))
    refute Map.has_key?(reading, :notes)

    {:ok, holder, _html} = live(signed_in_as(conn, @voter), "#{@list}/#{poll.id}")
    assert has_element?(holder, "#poll-notes", @notes)
    assert has_element?(holder, "#poll-my-vote", "Your Key voted for Left door.")
    refute has_element?(holder, "#poll-each-vote")

    Polls.end_poll!(poll, @fleet, actor: human(@starter))
    FleetPolls.read(@fleet)

    # Once it closes, anyone sees the counts; only the holder reads every Key's
    # vote, a moment later.
    assert shows?(fn -> has_element?(visitor, "#poll-results", "Most votes: Left door") end)
    assert shows?(fn -> has_element?(holder, "#poll-each-vote", "Key 2") end, 40)
    refute has_element?(visitor, "#poll-each-vote")
  end

  test "a burst of votes is answered by one read of the fleet, for every open page", %{
    conn: conn
  } do
    poll = start!()
    producer = start_supervised!(FleetPolls)

    # Watch the fleets the producer reads; the two open pages read nothing.
    :erlang.trace_pattern({FleetPolls, :read, 1}, true, [:global])
    :erlang.trace(producer, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({FleetPolls, :read, 1}, false, [:global]) end)

    # The producer reads the fleet once more after it first hears the open
    # poll; the burst starts after that read.
    assert_receive {:trace, ^producer, :call, {FleetPolls, :read, [@fleet]}}, 2_000

    {:ok, _view, _html} = live(conn, "#{@list}/#{poll.id}")
    {:ok, _view, _html} = live(conn, "#{@list}/#{poll.id}")

    vote!(poll, @voter)
    vote!(poll, @starter)

    assert_receive {:trace, ^producer, :call, {FleetPolls, :read, [@fleet]}}, 2_000
    refute_receive {:trace, ^producer, :call, {FleetPolls, :read, _}}, 1_500
  end

  # Several agents act for one Key; a reader has to see which started a poll
  # and which cast a vote.
  test "a poll and a vote an agent sent name the agent beside its Key", %{conn: conn} do
    agent = PairingHelpers.agent_for!(human(@starter))

    poll =
      Polls.start_poll!(
        %{
          fleet_id: @fleet,
          question: "Which door next?",
          choices: ["Left door", "Right door"],
          minutes: 30
        },
        actor: agent
      )

    Polls.cast_vote!(%{fleet_id: @fleet, poll_id: poll.id, choice: "Left door"}, actor: agent)
    Polls.end_poll!(poll, @fleet, actor: human(@starter))

    {:ok, list, _html} = open(conn, @list)
    assert has_element?(list, "#poll-#{poll.id}", "Started by Their agent (Key 1)")

    {:ok, holder, _html} = open(signed_in_as(conn, @voter), "#{@list}/#{poll.id}")
    assert has_element?(holder, "#poll-status", "Their agent (Key 1)")

    each_vote = ~r/Their agent \(Key 1\)\s+chose Left door/
    assert shows?(fn -> has_element?(holder, "#poll-each-vote", each_vote) end, 40)
  end

  defp start! do
    Polls.start_poll!(
      %{
        fleet_id: @fleet,
        question: "Which door next?",
        choices: ["Left door", "Right door"],
        notes: @notes,
        minutes: 30
      },
      actor: human(@starter)
    )
  end

  defp vote!(poll, wallet) do
    Polls.cast_vote!(%{fleet_id: @fleet, poll_id: poll.id, choice: "Left door"},
      actor: human(wallet)
    )
  end

  defp human(wallet), do: %Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:polls:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

  # Pages draw on the readings `KeyfleetWeb.FleetPolls` shares, and its
  # producer doesn't run under test, so a page opens on a fresh read of the
  # fleet, taken after the test has written what the page shows.
  defp open(conn, path) do
    FleetPolls.read(@fleet)
    live(conn, path)
  end

  # Polls every tenth of a second, `tries` times.
  defp shows?(check, tries \\ 30) do
    Enum.any?(1..tries, fn _try ->
      check.() or
        (
          Process.sleep(100)
          false
        )
    end)
  end
end
