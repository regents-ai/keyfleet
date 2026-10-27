defmodule Keyfleet.Projects do
  @moduledoc """
  The projects inside each fleet. A project gives one piece of the fleet's
  work its own board, its own space in the fleet's notebook hub and its own
  repository in the code store. Every fleet starts with one, `general`, which
  holds the starting goals, the fleet's first notebook space and its first
  repository.

  Every member of the fleet sees every project and works in any of them:
  membership is the fleet's, never a project's. Visitors see each project's
  title and the titles of the goals inside it, and nothing else of the
  workspace.

  Any Key holder whose edits a vote has not restricted starts a project, the
  same rule as starting a goal (`Keyfleet.Graph.Checks.KeyActor`). A fleet
  holds at most 20 projects. A project is
  never renamed, moved or removed.
  """
  use Ash.Domain

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
      define :record_space, action: :record_space, args: [:hub_project_id]
    end
  end

  @doc "The project every fleet starts with, which holds the starting goals."
  def general, do: "general"
end
