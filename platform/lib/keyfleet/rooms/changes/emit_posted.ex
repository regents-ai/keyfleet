defmodule Keyfleet.Rooms.Changes.EmitPosted do
  @moduledoc """
  Emits `:message_posted` (`Keyfleet.Rooms.Signals`) for a post the save made,
  with the Key it is written as and the wallets of the person who wrote it or
  whose agent did. A repeat the database handed back emits nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, &emit(&1, &2, context.actor))
  end

  defp emit(changeset, message, actor) do
    if Ash.Resource.get_metadata(message, :upsert_skipped) do
      {:ok, message}
    else
      payload = %{
        message_id: message.id,
        fleet_id: message.fleet_id,
        token_id: message.as_key,
        wallets: Keyfleet.Keys.person_wallets(actor)
      }

      with :ok <- Ash.Signals.emit(changeset, Keyfleet.Rooms.Signals, :message_posted, payload),
           do: {:ok, message}
    end
  end
end
