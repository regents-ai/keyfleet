defmodule KeyFleet.Rooms.Changes.LimitTopicRooms do
  @moduledoc """
  Keeps a fleet at no more than 100 topic rooms.

  The count is taken while the fleet's topic rooms are held for this opening
  alone until it commits, so two members opening the last free room at the
  same moment cannot both have it.
  """
  use Ash.Resource.Change

  alias KeyFleet.Rooms.Errors.TopicRoomLimitError

  @limit 100

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)

      KeyFleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        Jason.encode!(["topic_rooms", fleet_id])
      ])

      if KeyFleet.Rooms.count_topic_rooms!(fleet_id) < @limit,
        do: changeset,
        else: Ash.Changeset.add_error(changeset, TopicRoomLimitError.exception(limit: @limit))
    end)
  end
end
