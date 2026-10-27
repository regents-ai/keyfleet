defmodule Keyfleet.Projects do
  @moduledoc """
  The projects inside each fleet. A project gives one piece of the fleet's
  work its own board, its own space in the fleet's notebook hub and its own
  repository in the code store. Every fleet has `general`, archived and held
  by Key 3, which holds the starting goals, the fleet's first notebook space
  and its first repository.

  Each project is held by one of the fleet's Keys and is active, archived or
  deleted. A Key holds at most one active project and five archived ones; it
  starts, archives, takes over and deletes them as `Keyfleet.Projects.Project`
  says. New work goes into any active project, whoever holds it; an archived
  one takes no writes until a Key takes it over.

  Every member of the fleet sees every project that is not deleted and works
  in any active one: membership is the fleet's, never a project's. Visitors
  see each project's title and the titles of the goals inside it, and
  nothing else of the workspace.

  Acting as a Key is the same rule as every workspace write
  (`Keyfleet.Graph.Checks.KeyActor`). A project is never renamed or moved,
  and a deleted project's name is never used again.
  """
  use Ash.Domain

  alias Keyfleet.Projects.Errors.ClosedError

  resources do
    resource Keyfleet.Projects.Project do
      define :projects, action: :in_fleet, args: [:fleet_id]
      define :project_titles, action: :titles, args: [:fleet_id]
      define :project, action: :named, args: [:fleet_id, :name], not_found_error?: false

      define :project_of_repository,
        action: :by_repository,
        args: [:repository],
        not_found_error?: false

      define :start_project, action: :start, args: [:fleet_id, :as_key, :name, :title]
      define :archive_project, action: :archive, args: [:fleet_id, :as_key]
      define :take_over_project, action: :take_over, args: [:fleet_id, :as_key, :name]
      define :delete_project, action: :delete, args: [:fleet_id, :as_key, :name]
      define :record_space, action: :record_space, args: [:hub_project_id]
    end
  end

  @doc "The project every fleet has, which holds the starting goals."
  def general, do: "general"

  @doc """
  Gives each of these fleets its `general`, archived and held by Key 3,
  unless it has it already; a fleet that has it keeps it as it is.
  """
  def bootstrap_general!(fleet_ids) do
    Ash.bulk_create!(
      Enum.map(fleet_ids, &%{fleet_id: &1}),
      Keyfleet.Projects.Project,
      :general,
      actor: %Keyfleet.Actors.System{},
      return_errors?: true,
      stop_on_error?: true,
      transaction: :all,
      sorted?: true
    )

    :ok
  end

  @doc """
  The fleet's project `name` as `{:ok, project}` while it is active, so it
  takes new work; else `{:error, %ClosedError{}}` naming the fleet's active
  projects, for an archived project or a name the fleet has none by.
  """
  def open(fleet_id, name) do
    projects = projects!(fleet_id, actor: %Keyfleet.Actors.System{})
    active = for %{state: :active, name: active} <- projects, do: active

    case Enum.find(projects, &(&1.name == name)) do
      %{state: :active} = project ->
        {:ok, project}

      found ->
        code = if found, do: :project_archived, else: :project_unknown
        {:error, ClosedError.exception(code: code, project: name, active: active)}
    end
  end

  @doc """
  The fleet's projects for a member choosing where work goes: the active
  ones first, oldest first, then the archived ones.
  """
  def by_state(fleet_id, opts) do
    with {:ok, projects} <- projects(fleet_id, opts) do
      {:ok, Enum.sort_by(projects, &(&1.state != :active))}
    end
  end
end
