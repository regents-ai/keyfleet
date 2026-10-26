defmodule Keyfleet.Projects.Changes.Room do
  @moduledoc """
  Makes room for a new project in its fleet: names its repository, then, in
  the create's own transaction and holding the fleet's `general` row so that
  starts in one fleet take turns, refuses a name the fleet already uses and a
  fleet already holding the most projects it may.
  """
  use Ash.Resource.Change

  alias Keyfleet.Projects
  alias Keyfleet.Projects.Errors.{FullError, NameTakenError}
  alias Keyfleet.Projects.Project

  @system %Keyfleet.Actors.System{}

  @impl true
  def change(changeset, _opts, _context) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    name = Ash.Changeset.get_attribute(changeset, :name)

    changeset
    |> Ash.Changeset.force_change_attribute(:repository, "#{fleet_id}-#{name}")
    |> Ash.Changeset.before_action(&room(&1, fleet_id, name))
  end

  # Two statements: the second, read once the lock is held, sees every start
  # that held it before.
  defp room(changeset, fleet_id, name) do
    Project
    |> Ash.Query.for_read(:named, %{fleet_id: fleet_id, name: Projects.general()}, actor: @system)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()

    names = Enum.map(Projects.projects!(fleet_id, actor: @system), & &1.name)

    cond do
      name in names ->
        Ash.Changeset.add_error(
          changeset,
          NameTakenError.exception(fleet_id: fleet_id, name: name)
        )

      length(names) >= Project.most() ->
        Ash.Changeset.add_error(
          changeset,
          FullError.exception(fleet_id: fleet_id, most: Project.most())
        )

      true ->
        changeset
    end
  end
end
