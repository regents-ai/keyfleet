defmodule Keyfleet.Polls.Changes.OpenSession do
  @moduledoc """
  Opens a session with the opener's Key (`Keyfleet.Polls.voter/2`) as its
  delegate, for the minutes asked, and seats that Key in the same transaction.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.before_action(&delegate(&1, actor))
    |> Ash.Changeset.after_action(fn _changeset, session ->
      Polls.Seat
      |> Ash.Changeset.for_create(
        :seat_delegate,
        %{
          session_id: session.id,
          token_id: session.delegate_key,
          wallet: session.opened_by_wallet
        },
        actor: %System{}
      )
      |> Ash.create!()

      {:ok, session}
    end)
  end

  defp delegate(changeset, actor) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    minutes = Ash.Changeset.get_argument(changeset, :minutes)

    case Polls.voter(actor, fleet_id) do
      nil ->
        Ash.Changeset.add_error(changeset, NoKeyToWriteAsError.exception(fleet_id: fleet_id))

      %{key: key, wallet: wallet} ->
        Ash.Changeset.force_change_attributes(changeset, %{
          delegate_key: key,
          opened_by_wallet: wallet,
          expires_at: DateTime.add(DateTime.utc_now(), minutes, :minute)
        })
    end
  end
end
