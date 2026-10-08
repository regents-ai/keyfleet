defmodule Keyfleet.Rooms.Checks.PublicRoom do
  @moduledoc """
  Whether a room's posts are read in the one room of the fleet that anyone can
  read, General (`Keyfleet.Rooms.Room.public_slug/0`).
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Rooms.Room

  @impl true
  def describe(_opts), do: "the room is the fleet's General room"

  @impl true
  def match?(_actor, %{subject: %Ash.Query{} = query}, _opts),
    do: Ash.Query.get_argument(query, :slug) == Room.public_slug()
end
