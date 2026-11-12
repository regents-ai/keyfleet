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

  @fleet "fibonacci_syndicate"
  @list "/syndicate/1/polls"
  @starter ProposalHelpers.wallet("1")
  @voter ProposalHelpers.wallet("2")
  @outsider ProposalHelpers.wallet("3")
  @notes "The left one creaks."

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet, %{manager_address: "0x" <> String.duplicate("7", 40)})
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, [1], @starter)
    ProposalHelpers.keys_sold!(@fleet, [2], @voter)
    :ok
  end

  # Polls are for the fleet's Keys: a visitor, signed in or not, is told so
  # and is shown nothing of them.
  test "anyone holding none of the fleet's Keys sees that polls are for its Keys", %{
    conn: conn
  } do
    poll = start!()

    for reader <- [conn, signed_in_as(conn, @outsider)],
        path <- [@list, "#{@list}/#{poll.id}"] do
      {:ok, view, html} = live(reader, path)
      assert has_element?(view, "#polls-locked", "Keys only")
      refute html =~ "Which door next?"
      refute html =~ @notes
    end

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#polls-sign-in")
  end

  # A member's open page reads the poll again, as them, on each vote and on
  # its ending.
  test "a Key holder reads the notes, and each vote and the end reach their open page", %{
    conn: conn
  } do
    poll = start!()

    {:ok, holder, _html} = live(signed_in_as(conn, @voter), "#{@list}/#{poll.id}")
    {:ok, list, _html} = live(signed_in_as(conn, @starter), @list)

    assert has_element?(holder, "#poll-notes", @notes)
    assert has_element?(holder, "#poll-votes-so-far", "0 votes so far")
    assert has_element?(list, "#poll-#{poll.id}", "0 votes")

    vote!(poll, @voter)

    assert shows?(fn -> has_element?(holder, "#poll-votes-so-far", "1 vote so far") end)
    assert shows?(fn -> has_element?(list, "#poll-#{poll.id}", "1 vote") end)
    assert has_element?(holder, "#poll-my-vote", "Your Key voted for Left door.")

    Polls.end_poll!(poll, @fleet, actor: human(@starter))

    assert shows?(fn -> has_element?(holder, "#poll-results", "Most votes: Left door") end)
    assert has_element?(holder, "#poll-each-vote", "Key 2")
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

    {:ok, list, _html} = live(signed_in_as(conn, @voter), @list)
    assert has_element?(list, "#poll-#{poll.id}", "Started by Their agent (Key 1)")

    {:ok, holder, _html} = live(signed_in_as(conn, @voter), "#{@list}/#{poll.id}")
    assert has_element?(holder, "#poll-status", "Their agent (Key 1)")
    assert has_element?(holder, "#poll-each-vote", ~r/Their agent \(Key 1\)\s+chose Left door/)
  end

  # Ending a poll can't be undone, so End poll asks first in the site's
  # confirm window in the browser; its going-ahead press is this one.
  test "End poll asks first, and going ahead ends it", %{conn: conn} do
    poll = start!()
    {:ok, view, _html} = live(signed_in_as(conn, @starter), "#{@list}/#{poll.id}")
    assert has_element?(view, "#poll-votes-so-far")

    view |> element(~s(#poll-end[data-confirm-action="End"])) |> render_click()
    assert shows?(fn -> has_element?(view, "#poll-results") end)
    refute has_element?(view, "#poll-end")
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
