defmodule Keyfleet.Polls.Changes.OpenRound do
  @moduledoc """
  Opens a session's next round under the session's lock: the session must be
  open with no round open, the round takes the next number, and the Keys
  seated now are its roster. In the same transaction it writes
  `round_opened` to the log and queues the round's close at its deadline
  (`Keyfleet.Polls.Deadline`), so a round rolled back closes nothing.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.RoundOpenError
  alias Keyfleet.Polls.Errors.SessionEndedError
  alias Keyfleet.Polls.Errors.SessionUnknownError
  alias Keyfleet.Polls.Log
  alias Keyfleet.Polls.Round

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&number/1)
    |> Ash.Changeset.after_action(fn _changeset, round ->
      Log.append!(round.session_id, :round_opened, %{round: Round.to_map(round)})
      Oban.insert!(Polls.Deadline.new(%{round_id: round.id}, scheduled_at: round.deadline_at))
      {:ok, round}
    end)
  end

  defp number(changeset) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    session_id = Ash.Changeset.get_argument(changeset, :session_id)
    Log.lock!(session_id)

    with {:ok, _session} <- open_session(fleet_id, session_id),
         :ok <- none_open(session_id) do
      seconds = Ash.Changeset.get_argument(changeset, :deadline_seconds)

      Ash.Changeset.force_change_attributes(changeset, %{
        session_id: session_id,
        number: rounds(session_id) + 1,
        roster: Enum.map(Polls.seats_in_session!(session_id, actor: %System{}), & &1.token_id),
        deadline_at: DateTime.add(DateTime.utc_now(), seconds, :second)
      })
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp open_session(fleet_id, session_id) do
    case Polls.get_session!(fleet_id, session_id, actor: %System{}) do
      nil ->
        {:error, SessionUnknownError.exception(session_id: session_id)}

      session ->
        if Polls.open?(session),
          do: {:ok, session},
          else: {:error, SessionEndedError.exception([])}
    end
  end

  defp none_open(session_id) do
    Round
    |> Ash.Query.filter(session_id == ^session_id and status == :open)
    |> Ash.read_one!(actor: %System{})
    |> case do
      nil -> :ok
      open -> {:error, RoundOpenError.exception(number: open.number)}
    end
  end

  defp rounds(session_id),
    do: Round |> Ash.Query.filter(session_id == ^session_id) |> Ash.count!(actor: %System{})
end
