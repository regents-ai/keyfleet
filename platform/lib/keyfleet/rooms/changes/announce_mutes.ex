defmodule Keyfleet.Rooms.Changes.AnnounceMutes do
  @moduledoc """
  Once a mute is added or taken away, tells the muter's own open pages, so
  each shows or hides the key's posts again.
  """
  use Ash.Resource.Change

  alias Keyfleet.Rooms.Muter

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, mute} ->
        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Muter.topic(mute.muter),
          {:mutes_changed, mute.fleet_id}
        )

        {:ok, mute}

      _changeset, error ->
        error
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
