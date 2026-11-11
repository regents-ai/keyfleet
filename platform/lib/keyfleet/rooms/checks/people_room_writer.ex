defmodule Keyfleet.Rooms.Checks.PeopleRoomWriter do
  @moduledoc """
  Whether a post goes to the People and agents room
  (`Keyfleet.Rooms.Room.people_slug/0`) from someone who may write there
  (`Keyfleet.Access`, `:people_room`): anyone signed in, and any agent paired
  with a person.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Access
  alias Keyfleet.Rooms.Room

  @impl true
  def describe(_opts),
    do: "the post goes to the People and agents room, and the actor may write there"

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{} = changeset}, _opts),
    do:
      Ash.Changeset.get_argument(changeset, :slug) == Room.people_slug() and
        Access.allowed?(
          actor,
          :write,
          :people_room,
          Ash.Changeset.get_argument(changeset, :fleet_id)
        )
end
