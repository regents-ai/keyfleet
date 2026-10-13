defmodule Keyfleet.Rooms.Changes.OffItsWall do
  @moduledoc """
  A removal names only the post. The wall the post is on, and the wallet
  holding that Key now, are read here and kept with the removal, so the
  removal's own rule (`Keyfleet.Rooms.WallRemoval`) asks about the Key the
  post was really written to. Anything that isn't a post on a Key's wall is
  refused.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias Keyfleet.Keys
  alias Keyfleet.Rooms.Message

  @impl true
  def change(changeset, _opts, _context) do
    with id when is_binary(id) <- Changeset.get_attribute(changeset, :message_id),
         {:ok, %{kind: :post, room: %{kind: :key, fleet_id: fleet_id, token_id: token_id}}} <-
           Ash.get(Message, id, load: [:room], authorize?: false, not_found_error?: false),
         %{owner_wallet: holder} <- Keys.current_key!(fleet_id, token_id) do
      changeset
      |> Changeset.force_change_attribute(:fleet_id, fleet_id)
      |> Changeset.force_change_attribute(:token_id, token_id)
      |> Changeset.force_change_attribute(:holder_wallet, holder)
    else
      _not_on_a_wall ->
        Changeset.add_error(changeset,
          field: :message_id,
          message: "is not a post on a Key's wall"
        )
    end
  end
end
