defmodule KeyfleetWeb.PollJSON do
  @moduledoc """
  Poll sessions, seats and rounds as the agent API and the polls page's
  browser tools answer them.
  """

  alias Keyfleet.Polls

  @doc "A session, with its seated Keys and whether it still takes seats and rounds."
  def session(session) do
    %{
      id: session.id,
      name: session.name,
      mode: session.mode,
      delegate_key: session.delegate_key,
      seats: session.seat_keys,
      head_seq: session.head_seq,
      open: Polls.open?(session),
      expires_at: session.expires_at,
      ended_at: session.ended_at
    }
  end

  @doc "A Key's seat."
  def seat(seat), do: %{key: seat.token_id, joined_at: seat.inserted_at}

  @doc """
  A round as its reader may read it (`Keyfleet.Polls.Round`): everyone gets
  its moves and `totals`; only a seated Key's reader gets its `observation`
  and the `tally` with each Key's vote.
  """
  def round(round) do
    %{
      number: round.number,
      decision_ref: round.decision_ref,
      actions: Enum.map(round.actions, &%{id: &1.id, label: &1.label}),
      deadline_at: round.deadline_at,
      roster: round.roster,
      status: round.status,
      outcome: round.outcome,
      winner: round.winner,
      votes_cast: round.votes_cast,
      totals: round.totals,
      closed_at: round.closed_at
    }
    |> put_readable(:observation, round.observation)
    |> put_readable(:tally, round.tally)
  end

  defp put_readable(map, _field, %Ash.ForbiddenField{}), do: map
  defp put_readable(map, field, value), do: Map.put(map, field, value)
end
