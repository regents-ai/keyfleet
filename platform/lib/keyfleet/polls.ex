defmodule Keyfleet.Polls do
  @moduledoc """
  Fast polls: a fleet's Keys deciding one move together, in seconds.

  Anyone holding one of the fleet's Keys, or a shard of one, opens a session
  and is its delegate: a person on the fleet's polls page, or an agent (an
  agent paired with a person takes part as that person's Key). Others join
  it, each taking its Key's seat. The
  delegate opens a round for every decision the outside game or service asks
  for: what the agents see, the moves they may choose from and a deadline. The
  Keys seated when the round opens vote once each. A Key with several agents
  votes once: the first vote sent for it counts.

  In a `:poll` session every seated Key's vote counts; votes stay hidden until
  the round closes, and the move with the most votes wins, a tie going to the
  move whose votes carry the higher total confidence and then to the move
  listed first. In a `:delegate` session only the delegate's Key decides; the
  other Keys' votes are suggestions, shown to the session as they arrive. A
  round closes at its deadline, or as soon as every Key whose vote counts has
  voted, and its result never changes afterwards.

  Everything that happens in a session is written to its log in the same
  transaction as the change (`Keyfleet.Polls.Log`), in order, and announced on
  `topic/1` once committed, so an agent waiting on the session hears of it at
  once and one that reconnects reads on from the last place it saw.

  Anyone reads a fleet's sessions, their seats, and their rounds' moves and
  results: the winner and each move's count of votes. Only the seated Keys
  read a round's observation, each Key's vote, and the session's log.
  """
  use Ash.Domain

  alias Keyfleet.Actors.Agent

  resources do
    resource Keyfleet.Polls.Session do
      define :open_session, action: :open
      define :open_sessions, action: :open_in_fleet, args: [:fleet_id]
      define :list_sessions, action: :listed, args: [:fleet_id]
      define :get_session, action: :in_fleet, args: [:fleet_id, :id], not_found_error?: false
      define :end_session, action: :end, args: [:fleet_id]
    end

    resource Keyfleet.Polls.Seat do
      define :join, action: :join
      define :leave, action: :leave, args: [:fleet_id]

      define :get_seat,
        action: :of_key,
        args: [:session_id, :token_id],
        not_found_error?: false

      define :seats_in_session, action: :in_session, args: [:session_id]
    end

    resource Keyfleet.Polls.Round do
      define :open_round, action: :open
      define :close_round, action: :close
      define :get_round_by_id, action: :by_id, args: [:id], not_found_error?: false
      define :list_rounds, action: :of_session, args: [:fleet_id, :session_id]

      define :get_round,
        action: :in_session,
        args: [:session_id, :number],
        not_found_error?: false
    end

    resource Keyfleet.Polls.Vote do
      define :cast_vote, action: :cast
      define :votes_in_round, action: :in_round, args: [:round_id]

      define :my_vote,
        action: :mine,
        args: [:fleet_id, :session_id, :round_id],
        not_found_error?: false

      define :get_vote,
        action: :of_key,
        args: [:round_id, :token_id],
        not_found_error?: false
    end

    resource Keyfleet.Polls.Event do
      define :append_event, action: :append
      define :events_after, action: :after, args: [:fleet_id, :session_id, :after_seq]
    end
  end

  @doc "Where a session announces each line written to its log, as `\"poll_event\"`."
  def topic(session_id), do: "poll:#{session_id}"

  @doc "Where a fleet announces a session opened or ended, as `\"polls_changed\"`."
  def fleet_topic(fleet_id), do: "polls:#{fleet_id}"

  @doc """
  The Key `actor` takes part as in the fleet's polls, as `%{key: token_id,
  wallet: wallet}`, or nil: by `Keyfleet.Keys.identity/2`, so a person is the
  highest-ranked Key their wallets hold, an agent the Key its own wallet holds
  or holds a shard of, and an agent paired with a person here is that person's
  Key. `wallet` is the one that acted: the agent's own, or the person's wallet
  holding the Key.
  """
  def voter(actor, fleet_id) do
    case Keyfleet.Keys.identity(actor, fleet_id) do
      nil ->
        nil

      %{token_id: token_id, wallet: wallet} ->
        %{key: token_id, wallet: acting_wallet(actor, wallet)}
    end
  end

  defp acting_wallet(%Agent{wallet_address: wallet}, _key_wallet), do: wallet
  defp acting_wallet(_person, key_wallet), do: key_wallet

  @doc "Whether the session still takes seats and rounds: not ended, and not past its time."
  def open?(session),
    do: is_nil(session.ended_at) and DateTime.after?(session.expires_at, DateTime.utc_now())
end
