defmodule Keyfleet.Rooms.Changes.LimitCreatedRooms do
  @moduledoc """
  Keeps a fleet at no more than 100 created rooms, beside its own ten.

  The count is taken while the fleet's created rooms are held for this one
  alone until it commits, so two agents creating the last free room at the
  same moment cannot both have it.
  """
  use Ash.Resource.Change

  alias Keyfleet.Rooms.Errors.CreatedRoomLimitError

  @limit 100

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)

      Keyfleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        Jason.encode!(["created_rooms", fleet_id])
      ])

      if Keyfleet.Rooms.count_created_rooms!(fleet_id) < @limit,
        do: changeset,
        else: Ash.Changeset.add_error(changeset, CreatedRoomLimitError.exception(limit: @limit))
    end)
  end
end
