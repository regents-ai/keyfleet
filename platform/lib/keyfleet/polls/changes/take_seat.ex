defmodule Keyfleet.Polls.Changes.TakeSeat do
  @moduledoc """
  Seats a Key in a session and writes `seat_joined` to the session's log.

  With `as: :actor`, the Key is the one the actor takes part as
  (`Keyfleet.Polls.voter/2`), read under the
  session's lock, and the session must still be open. A Key already seated
  keeps its seat and nothing is written. With `as: :delegate`, the seat is the
  delegate's, taken in the transaction that opens the session.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.SessionEndedError
  alias Keyfleet.Polls.Errors.SessionUnknownError
  alias Keyfleet.Polls.Log
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError

  @impl true
  def change(changeset, opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.before_action(&seat(&1, Keyword.fetch!(opts, :as), actor))
    |> Ash.Changeset.after_action(&announce/2)
  end

  defp seat(changeset, :delegate, _actor) do
    Ash.Changeset.force_change_attributes(changeset, %{
      session_id: Ash.Changeset.get_argument(changeset, :session_id),
      token_id: Ash.Changeset.get_argument(changeset, :token_id),
      joined_by_wallet: Ash.Changeset.get_argument(changeset, :wallet)
    })
  end

  defp seat(changeset, :actor, actor) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    session_id = Ash.Changeset.get_argument(changeset, :session_id)
    Log.lock!(session_id)

    case {Polls.get_session!(fleet_id, session_id, actor: %System{}),
          Polls.voter(actor, fleet_id)} do
      {nil, _key} ->
        Ash.Changeset.add_error(changeset, SessionUnknownError.exception(session_id: session_id))

      {_session, nil} ->
        Ash.Changeset.add_error(changeset, NoKeyToWriteAsError.exception(fleet_id: fleet_id))

      {session, %{key: key, wallet: wallet}} ->
        if Polls.open?(session) do
          Ash.Changeset.force_change_attributes(changeset, %{
            session_id: session_id,
            token_id: key,
            joined_by_wallet: wallet
          })
        else
          Ash.Changeset.add_error(changeset, SessionEndedError.exception([]))
        end
    end
  end

  defp announce(_changeset, seat) do
    unless Ash.Resource.get_metadata(seat, :upsert_skipped),
      do: Log.append!(seat.session_id, :seat_joined, %{key: seat.token_id})

    {:ok, seat}
  end
end
