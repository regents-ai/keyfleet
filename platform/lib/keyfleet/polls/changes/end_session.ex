defmodule Keyfleet.Polls.Changes.EndSession do
  @moduledoc """
  Ends a session that is still open and writes `session_ended` to its log. A
  round still open closes at its own deadline.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.SessionEndedError
  alias Keyfleet.Polls.Log

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&close/1)
    |> Ash.Changeset.after_action(fn _changeset, session ->
      Log.append!(session.id, :session_ended, %{})
      {:ok, session}
    end)
  end

  # The session is read again under its lock: it may have ended since.
  defp close(%{data: session} = changeset) do
    Log.lock!(session.id)
    current = Polls.get_session!(session.fleet_id, session.id, actor: %System{})

    if Polls.open?(current),
      do: Ash.Changeset.force_change_attribute(changeset, :ended_at, DateTime.utc_now()),
      else: Ash.Changeset.add_error(changeset, SessionEndedError.exception([]))
  end
end
