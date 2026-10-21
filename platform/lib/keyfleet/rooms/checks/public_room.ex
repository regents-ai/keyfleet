defmodule Keyfleet.Rooms.Checks.PublicRoom do
  @moduledoc """
  Whether a room's posts are read in the fleet's Public room
  (`Keyfleet.Rooms.Room.public_slug/0`) by someone who may read the Public room
  (`Keyfleet.Access`, `:general_room`): the room `slug` names, or every room
  `slugs` names in a catch-up across rooms.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Access
  alias Keyfleet.Rooms.Room

  @impl true
  def describe(_opts), do: "the room is the fleet's Public room"

  @impl true
  def match?(actor, %{subject: %Ash.Query{} = query}, _opts),
    do:
      Enum.all?(slugs(query), &(&1 == Room.public_slug())) and
        Access.allowed?(actor, :read, :general_room, Ash.Query.get_argument(query, :fleet_id))

  defp slugs(%Ash.Query{action: %{name: :catch_up}} = query),
    do: Ash.Query.get_argument(query, :slugs)

  defp slugs(query), do: [Ash.Query.get_argument(query, :slug)]
end
