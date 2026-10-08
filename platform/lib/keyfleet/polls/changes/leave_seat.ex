defmodule Keyfleet.Polls.Changes.LeaveSeat do
  @moduledoc """
  Gives up a Key's seat and writes `seat_left` to the session's log. The
  delegate's Key ends the session instead. A Key that leaves keeps no vote in
  a round still open.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.DelegateStaysError
  alias Keyfleet.Polls.Log

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&check/1)
    |> Ash.Changeset.after_action(fn _changeset, seat ->
      Log.append!(seat.session_id, :seat_left, %{key: seat.token_id})
      {:ok, seat}
    end)
  end

  defp check(%{data: seat} = changeset) do
    Log.lock!(seat.session_id)
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)

    case Polls.get_session!(fleet_id, seat.session_id, actor: %System{}) do
      %{delegate_key: key} when key == seat.token_id ->
        Ash.Changeset.add_error(changeset, DelegateStaysError.exception([]))

      _session ->
        changeset
    end
  end
end
