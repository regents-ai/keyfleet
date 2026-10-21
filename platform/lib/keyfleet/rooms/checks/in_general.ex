defmodule Keyfleet.Rooms.Checks.InGeneral do
  @moduledoc """
  The fleet's Public room (`Keyfleet.Rooms.Room.public_slug/0`) and the lines
  written in it, for reads that name their fleet and for whoever may read
  the Public room (`Keyfleet.Access`, `:general_room`). A read without a fleet has
  none.

  For lines, the Public room's id is found once, in the same statement, so the read
  keeps to its index on the fleet's room and time
  (`messages_fleet_room_lines_index`) rather than joining every line to its
  room.
  """
  use Ash.Policy.FilterCheck

  alias Keyfleet.Access
  alias Keyfleet.Rooms.Message
  alias Keyfleet.Rooms.Room

  @impl true
  def describe(_opts), do: "it is the fleet's Public room, or a line in it"

  @impl true
  def filter(actor, %{query: %Ash.Query{} = query}, _opts) do
    fleet_id = Ash.Query.get_argument(query, :fleet_id)

    if is_binary(fleet_id) and Access.allowed?(actor, :read, :general_room, fleet_id),
      do: general(query.resource, fleet_id),
      else: expr(false)
  end

  defp general(Room, _fleet_id), do: expr(slug == ^Room.public_slug())

  defp general(Message, fleet_id),
    do:
      expr(
        room_id ==
          fragment(
            "(SELECT general.id FROM keyfleet_app.rooms AS general WHERE general.fleet_id = ? AND general.slug = ?)",
            ^fleet_id,
            ^Room.public_slug()
          )
      )
end
