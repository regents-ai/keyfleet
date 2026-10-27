defmodule KeyfleetWeb.ProjectPage do
  @moduledoc """
  What a project's page reads, at the fleet's address and the project's name,
  such as `/classic/1/projects/virtual-cell`: the project, its open goals by
  title as every visitor sees them, and, once the Key holding it shows its
  work to everyone (`Keyfleet.Projects.Project`), its latest work, what it
  produced and the tasks open to take, each by title, with how many there are
  of each. A project's page never shows more than titles: members read the
  rest in the workspace.

  A name that is no project of the fleet, or a deleted one's, is a page that
  doesn't exist.
  """

  alias Keyfleet.{Fleets, Graph, Projects}
  alias Keyfleet.Graph.Object
  alias KeyfleetWeb.{DirectoryMD, NotFoundError, WorkspacePage}

  # How many of each part the page lists, newest first.
  @shown 6
  @parts [:goals, :work, :outputs, :open]

  @doc "The page of the project `name` in the fleet `fleet_id`."
  def read(fleet_id, name) do
    case Projects.project_page!(fleet_id, name) do
      nil -> raise NotFoundError
      project -> page(fleet_id, project)
    end
  end

  @doc "A project page's address."
  def path(fleet_id, name), do: Fleets.path(fleet_id) <> "/projects/" <> name

  defp page(fleet_id, project) do
    path = path(fleet_id, project.name)

    %{
      fleet_id: fleet_id,
      fleet_name: Fleets.name(fleet_id),
      fleet_path: Fleets.path(fleet_id),
      name: project.name,
      title: seen(project.title, "A project"),
      key: project.key,
      state: project.state,
      shown?: project.shown_to_everyone,
      pair_path: "/pair?to=" <> URI.encode_www_form(path),
      workspace_path: WorkspacePage.place_path(fleet_id, :project, project.name),
      goals: if(not project.shown_to_everyone, do: goal_titles(fleet_id, project.name)),
      parts: if(project.shown_to_everyone, do: parts(fleet_id, project.name))
    }
  end

  defp goal_titles(fleet_id, name) do
    fleet_id
    |> Graph.open_goals!(%{project: name}, query: [limit: @shown])
    |> Enum.map(&seen(&1.title, "A goal"))
  end

  # Every part from one moment of the read tables.
  defp parts(fleet_id, name) do
    {:ok, parts} =
      Graph.in_snapshot(fn -> Map.new(@parts, &{&1, part(fleet_id, name, &1)}) end)

    parts
  end

  defp part(fleet_id, name, part) do
    query = Ash.Query.for_read(Object, :shown, %{fleet_id: fleet_id, project: name, part: part})

    %{
      items: query |> Ash.Query.limit(@shown) |> Ash.read!() |> Enum.map(&item/1),
      count: Ash.count!(query)
    }
  end

  defp item(object) do
    {type, _plural} = WorkspacePage.type_name(object.type)

    %{
      id: object.id,
      type: type,
      title: seen(object.title, "Untitled"),
      standing: standing(object.type, object.standing)
    }
  end

  # The graph keeps each status and progress to its choices.
  defp standing(_type, nil), do: nil
  defp standing("goal", status), do: WorkspacePage.choice("status", status)

  defp standing("task", standing) when standing in ~w(awaiting_review accepted disputed),
    do: WorkspacePage.choice("review", standing)

  defp standing("task", progress), do: WorkspacePage.choice("progress", progress)
  defp standing(_type, _standing), do: nil

  defp seen(title, untitled) do
    case (title || "") |> DirectoryMD.visible() |> String.trim() do
      "" -> untitled
      title -> title
    end
  end
end
