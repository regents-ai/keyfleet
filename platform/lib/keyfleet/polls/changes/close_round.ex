defmodule Keyfleet.Polls.Changes.CloseRound do
  @moduledoc """
  Closes a round once, under its session's lock: the votes in by then give its
  result (`Keyfleet.Polls.Tally`), and `round_closed` goes to the log with the
  result and every vote revealed. A round already closed is refused with
  `AlreadyClosedError`, so its result is never written twice.

  Emits `[:keyfleet, :polls, :round_closed]` with `open_ms`, `votes` and
  `roster`, and metadata `outcome` and `early` (closed before its deadline).
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.AlreadyClosedError
  alias Keyfleet.Polls.Log
  alias Keyfleet.Polls.Round
  alias Keyfleet.Polls.Tally

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&result/1)
    |> Ash.Changeset.after_action(fn _changeset, round ->
      Log.append!(round.session_id, :round_closed, %{round: Round.to_map(round)})
      measure(round)
      {:ok, round}
    end)
  end

  defp result(%{data: round} = changeset) do
    Log.lock!(round.session_id)

    case Polls.get_round_by_id!(round.id, actor: %System{}) do
      %{status: :closed} ->
        Ash.Changeset.add_error(changeset, AlreadyClosedError.exception([]))

      current ->
        votes = Polls.votes_in_round!(round.id, actor: %System{})
        %{outcome: outcome, winner: winner, tally: tally} = Tally.decide(current.actions, votes)

        Ash.Changeset.force_change_attributes(changeset, %{
          status: :closed,
          outcome: outcome,
          winner: winner,
          votes_cast: Enum.count(votes, & &1.counted),
          tally: tally,
          closed_at: DateTime.utc_now()
        })
    end
  end

  defp measure(round) do
    :telemetry.execute(
      [:keyfleet, :polls, :round_closed],
      %{
        open_ms: DateTime.diff(round.closed_at, round.inserted_at, :millisecond),
        votes: round.votes_cast,
        roster: length(round.roster)
      },
      %{outcome: round.outcome, early: DateTime.before?(round.closed_at, round.deadline_at)}
    )
  end
end
