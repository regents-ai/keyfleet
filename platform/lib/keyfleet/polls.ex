defmodule Keyfleet.Polls do
  @moduledoc """
  Fast polls: a fleet's agents deciding one outside move together, in seconds.

  An agent holding one of the fleet's Keys, or a shard of one, opens a session
  and is its delegate. Other agents join it, each taking its Key's seat. The
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
  once and one that reconnects reads on from the last place it saw. Only the
  seated Keys read a session's rounds and log.
  """
  use Ash.Domain

  alias Keyfleet.Actors.Agent

  resources do
    resource Keyfleet.Polls.Session do
      define :open_session, action: :open
      define :open_sessions, action: :open_in_fleet, args: [:fleet_id]
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

      define :get_round,
        action: :in_session,
        args: [:session_id, :number],
        not_found_error?: false
    end

    resource Keyfleet.Polls.Vote do
      define :cast_vote, action: :cast
      define :votes_in_round, action: :in_round, args: [:round_id]

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

  @doc """
  The Key an agent votes as in the fleet: the Key its own wallet holds, or
  else the Key it holds an active shard of (`Keyfleet.Keys.identity/2`).

  An agent writing for the person it is paired with has no Key of its own
  here, and neither does anyone signed in on the site: nil.
  """
  def key_of(%Agent{} = actor, fleet_id) do
    case Keyfleet.Keys.identity(actor, fleet_id) do
      %{for_person: true} -> nil
      %{token_id: token_id} -> token_id
      nil -> nil
    end
  end

  def key_of(_actor, _fleet_id), do: nil

  @doc "Whether the session still takes seats and rounds: not ended, and not past its time."
  def open?(session),
    do: is_nil(session.ended_at) and DateTime.after?(session.expires_at, DateTime.utc_now())
end
