defmodule KeyFleet.Rooms.Changes.AnnouncePost do
  @moduledoc """
  Tells everyone watching the fleet's rooms that a room has taken a new post,
  once the post is committed.

  Best effort, and only for a post that is new. Anyone reading a room reads it
  from the room itself, so a notice that never arrives costs nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_transaction(changeset, &announce/2)

  defp announce(_changeset, {:ok, message} = result) do
    unless Ash.Resource.get_metadata(message, :upsert_skipped) do
      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        KeyFleet.Rooms.fleet_topic(message.fleet_id),
        {:room_head, message.room_id, message.seq}
      )
    end

    result
  end

  defp announce(_changeset, result), do: result
end
