defmodule KeyFleet.Rooms.Changes.AnnouncePost do
  @moduledoc """
  Tells everyone watching the fleet's rooms that a room has taken a new post,
  once the post is committed, and that the keys it concerns have something new:
  the key it was written as, and the key whose thread it was written to.

  Best effort, and only for a post that is new. Anyone reading a room reads it
  from the room itself, so a notice that never arrives costs nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_transaction(changeset, &announce/2)

  defp announce(changeset, {:ok, message} = result) do
    unless Ash.Resource.get_metadata(message, :upsert_skipped) do
      topic = KeyFleet.Rooms.fleet_topic(message.fleet_id)

      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        topic,
        {:room_head, message.room_id, message.seq}
      )

      for token_id <- Enum.uniq([message.as_key, thread_key(changeset)]), token_id != nil do
        Phoenix.PubSub.broadcast(
          KeyFleet.PubSub,
          topic,
          {:key_activity, message.fleet_id, token_id}
        )
      end
    end

    result
  end

  defp announce(_changeset, result), do: result

  # Only a post written to a key names the key whose thread it is in.
  defp thread_key(changeset), do: Ash.Changeset.get_argument(changeset, :token_id)
end
