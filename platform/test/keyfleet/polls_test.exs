defmodule Keyfleet.PollsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Polls
  alias Keyfleet.Repo

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    epoch!(token_id: 1, owner_wallet: wallet("a"))
    epoch!(token_id: 2, owner_wallet: wallet("b"))
    :ok
  end

  # Polls are public to read, but a Key's own vote, how sure it was and why,
  # and what the round showed its voters, stay with the session's seated Keys.
  test "anyone reads a round's totals; only seated Keys read each vote" do
    leader = human("a")
    voter = human("b")

    session =
      Polls.open_session!(%{fleet_id: @fleet, name: "Hull plan", mode: :poll, minutes: 60},
        actor: leader
      )

    assert %{delegate_key: 1, opened_by_wallet: opened_by} = session
    assert opened_by == wallet("a")
    Polls.join!(%{fleet_id: @fleet, session_id: session.id}, actor: voter)

    Polls.open_round!(
      %{
        fleet_id: @fleet,
        session_id: session.id,
        decision_ref: "turn-1",
        observation: %{"board" => "two doors"},
        actions: [%{id: "left", label: "Go left"}, %{id: "right", label: "Go right"}],
        deadline_seconds: 60
      },
      actor: leader
    )

    for {actor, move} <- [{leader, "left"}, {voter, "left"}] do
      Polls.cast_vote!(
        %{fleet_id: @fleet, session_id: session.id, number: 1, action: move, reason: "open"},
        actor: actor
      )
    end

    for outsider <- [nil, human("c")] do
      [round] = Polls.list_rounds!(@fleet, session.id, actor: outsider)
      assert %{status: :closed, winner: "left"} = round
      assert round.totals == [%{action: "left", votes: 2}, %{action: "right", votes: 0}]
      assert %Ash.ForbiddenField{} = round.tally
      assert %Ash.ForbiddenField{} = round.observation
    end

    [round] = Polls.list_rounds!(@fleet, session.id, actor: voter)
    assert %{"board" => "two doors"} = round.observation
    assert [%{"key" => 1, "reason" => "open"}, %{"key" => 2}] = round.tally["votes"]

    assert %{token_id: 2, wallet: by} =
             Polls.my_vote!(@fleet, session.id, round.id, actor: voter)

    assert by == wallet("b")
  end

  test "a poll lasts at most an hour" do
    assert {:error, %Ash.Error.Invalid{}} =
             Polls.open_session(%{fleet_id: @fleet, name: "Long", mode: :poll, minutes: 61},
               actor: human("a")
             )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 1,
      owner_wallet: wallet("a"),
      block_number: 10,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{event.token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
