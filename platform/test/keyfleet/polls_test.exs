defmodule Keyfleet.PollsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.AgentVotingOffError
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

  # Only the fleet's Key holders read its polls; anyone else, signed in or
  # not, is refused them. Each Key's vote shows once the poll closes.
  test "only Key holders read a poll, its notes and, once it closes, its votes" do
    starter = human("a")
    voter = human("b")

    poll =
      Polls.start_poll!(
        %{
          fleet_id: @fleet,
          question: "Which door next?",
          choices: ["Left door", "Right door"],
          notes: "The left one creaks.",
          minutes: 30
        },
        actor: starter
      )

    assert %{started_by_key: 1, started_by_wallet: by} = poll
    assert by == wallet("a")

    for {actor, choice} <- [{starter, "Left door"}, {voter, "Left door"}] do
      Polls.cast_vote!(
        %{fleet_id: @fleet, poll_id: poll.id, choice: choice, reason: "open"},
        actor: actor
      )
    end

    assert %{totals: nil, votes_cast: 2} = Polls.get_poll!(@fleet, poll.id, actor: voter)
    assert [] = Polls.votes_in_poll!(@fleet, poll.id, actor: voter)

    Polls.end_poll!(poll, @fleet, actor: starter)

    for outsider <- [nil, human("c")] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Polls.list_polls(@fleet, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Polls.get_poll(@fleet, poll.id, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Polls.votes_in_poll(@fleet, poll.id, actor: outsider, authorize_with: :error)
    end

    assert %{notes: "The left one creaks.", totals: totals} =
             Polls.get_poll!(@fleet, poll.id, actor: voter)

    assert totals == [%{choice: "Left door", votes: 2}, %{choice: "Right door", votes: 0}]

    assert [%{token_id: 1, reason: "open"}, %{token_id: 2}] =
             @fleet |> Polls.votes_in_poll!(poll.id, actor: voter) |> Enum.sort_by(& &1.token_id)

    assert %{token_id: 2, wallet: voted_by} = Polls.my_vote!(@fleet, poll.id, actor: voter)
    assert voted_by == wallet("b")
  end

  test "each Key starts one poll in any 24 hours" do
    start = fn question ->
      Polls.start_poll(
        %{fleet_id: @fleet, question: question, choices: ["Yes", "No"], minutes: 1},
        actor: human("a")
      )
    end

    assert {:ok, _poll} = start.("First?")
    assert {:error, %Ash.Error.Invalid{errors: errors}} = start.("Second?")
    assert [%Keyfleet.Polls.Errors.PollLimitError{retry_after: wait}] = errors
    assert wait in 86_399..86_400
  end

  test "a poll stays open from 1 minute to an hour" do
    for minutes <- [0, 61] do
      assert {:error, %Ash.Error.Invalid{}} =
               Polls.start_poll(
                 %{fleet_id: @fleet, question: "Long?", choices: ["Yes", "No"], minutes: minutes},
                 actor: human("a")
               )
    end
  end

  # An agent with only a shard of a Key votes for it as the fleet's proposals
  # let it: while the Key's owner has not turned its agents' voting off.
  test "an agent holding only a shard of a Key votes while the Key's agent voting is on" do
    ChainHelpers.deploy!(@fleet)

    poll =
      Polls.start_poll!(
        %{fleet_id: @fleet, question: "Which door?", choices: ["Left", "Right"], minutes: 30},
        actor: human("a")
      )

    agent = PairingHelpers.pair_wallet!(wallet("d"), wallet("c"))
    ChainHelpers.issue_shard!(@fleet, 2, agent.wallet_address)

    vote = fn ->
      Polls.cast_vote(%{fleet_id: @fleet, poll_id: poll.id, choice: "Left"}, actor: agent)
    end

    agent_voting!(2, false, 1)
    assert {:error, %Ash.Error.Forbidden{errors: [%AgentVotingOffError{token_id: 2}]}} = vote.()

    agent_voting!(2, true, 2)
    assert {:ok, %{token_id: 2, wallet: voted_by}} = vote.()
    assert voted_by == wallet("d")
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  # The Key owner's agents' voting turned on or off, as the `number`th setting
  # on the chain, in the Key's first ownership.
  defp agent_voting!(token_id, allowed, number) do
    Keys.record_agent_voting!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        allowed: allowed,
        ownership_epoch: 1,
        block_number: 20 + number,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("e#{number}", 32),
        log_index: 0
      },
      actor: @system
    )
  end

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
