defmodule Keyfleet.Polls.Log do
  @moduledoc """
  The order of everything that happens in one poll session.

  Every change to a session (a seat taken or given up, a round opened or
  closed, a suggestion, the session ending) first holds the session with
  `lock!/1`, then writes its line with `append!/3` inside the same
  transaction, so the log never misses a committed change or holds one that
  was rolled back. The count is kept on the session row and moved by the
  statement below; it is the only write to sessions made outside a resource
  action.
  """

  alias Keyfleet.Actors.System

  @doc "Holds every change to one session in line until the transaction commits."
  def lock!(session_id) do
    Keyfleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["poll", session_id])
    ])

    :ok
  end

  @doc "Writes the session's next line, of `kind` with `payload`, under the session's lock."
  def append!(session_id, kind, payload) do
    %Postgrex.Result{rows: [[seq]]} =
      Keyfleet.Repo.query!(
        "UPDATE keyfleet_app.poll_sessions SET head_seq = head_seq + 1 WHERE id = $1 RETURNING head_seq",
        [Ecto.UUID.dump!(session_id)]
      )

    Keyfleet.Polls.append_event!(
      %{session_id: session_id, seq: seq, kind: kind, payload: payload},
      actor: %System{}
    )
  end
end
