defmodule Keyfleet.Rooms.Checks.InGeneral do
  @moduledoc """
  The lines written in the fleet's General room
  (`Keyfleet.Rooms.Room.public_slug/0`), the one room of a fleet anyone reads,
  for reads that name their fleet. A read without a fleet has none.

  General's id is found once, in the same statement, so the read keeps to its
  index on the fleet's room and time (`messages_fleet_room_lines_index`)
  rather than joining every line to its room.
  """
  use Ash.Policy.FilterCheck

  alias Keyfleet.Rooms.Room

  @impl true
  def describe(_opts), do: "the line is in the fleet's General room"

  @impl true
  def filter(_actor, %{query: %Ash.Query{} = query}, _opts) do
    case Ash.Query.get_argument(query, :fleet_id) do
      nil ->
        expr(false)

      fleet_id ->
        expr(
          room_id ==
            fragment(
              "(SELECT general.id FROM keyfleet_app.rooms AS general WHERE general.fleet_id = ? AND general.slug = ?)",
              ^fleet_id,
              ^Room.public_slug()
            )
        )
    end
  end
end
