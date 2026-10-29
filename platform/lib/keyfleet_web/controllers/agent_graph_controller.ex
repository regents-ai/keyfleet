defmodule KeyfleetWeb.AgentGraphController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets, Graph, Notebooks, Projects}
  alias Keyfleet.Graph.Errors.WriteLimitError
  alias Keyfleet.Notebooks.HubClient
  alias KeyfleetWeb.{AgentTools, WorkspaceRefusal}

  @command ~w(as_key command_id)

  # The workspace's reads answer what the same tool at the Claude connector's
  # address does (`KeyfleetWeb.AgentTools.Workspace`).
  def view(conn, %{"fleet_id" => fleet_id} = params),
    do:
      answer_read(
        conn,
        AgentTools.workspace_view(
          fleet_id,
          Map.take(params, ~w(project type owner_key archived)),
          actor: conn.assigns.agent_actor
        )
      )

  def get_object(conn, %{"fleet_id" => fleet_id, "id" => id} = params),
    do:
      answer_read(
        conn,
        AgentTools.workspace_show(
          fleet_id,
          id,
          Map.take(params, ~w(relations_after fields)),
          actor: conn.assigns.agent_actor
        )
      )

  def changes(conn, %{"fleet_id" => fleet_id} = params),
    do:
      answer_read(
        conn,
        AgentTools.workspace_changes(
          fleet_id,
          Map.take(params, ~w(after_seq limit project object max_bytes)),
          actor: conn.assigns.agent_actor
        )
      )

  def board(conn, %{"fleet_id" => fleet_id} = params),
    do:
      answer_read(
        conn,
        AgentTools.workspace_board(fleet_id, Map.take(params, ~w(project)),
          actor: conn.assigns.agent_actor
        )
      )

  def create(conn, params),
    do: write(conn, &Graph.create_object/3, params, ~w(project type data))

  def patch(conn, params),
    do:
      write(
        conn,
        &Graph.patch_object/3,
        params,
        ~w(id expected_version set unset reason evidence)
      )

  def link(conn, params),
    do: write(conn, &Graph.link_objects/3, params, ~w(source target type note))

  def unlink(conn, params), do: write(conn, &Graph.unlink_relation/3, params, ~w(relation_id))

  def archive(conn, params),
    do: write(conn, &Graph.archive_object/3, params, ~w(id expected_version reason))

  def join(conn, params), do: write(conn, &Graph.join_goal/3, params, ~w(id))

  def leave(conn, params), do: write(conn, &Graph.leave_goal/3, params, ~w(id))

  def fork(conn, params), do: write(conn, &Graph.fork_task/3, params, ~w(id))

  def submit(conn, params),
    do:
      write(
        conn,
        &Graph.submit_task/3,
        params,
        ~w(id expected_version result_ref evidence reason)
      )

  def review(conn, params),
    do:
      write(
        conn,
        &Graph.review_task/3,
        params,
        ~w(task task_version decision rationale conflicts_of_interest reproduction)
      )

  # A pin on something a project keeps at hand, as the workspace page pins
  # one: a notebook in its Docs or a file or folder of its code, found in the
  # project as it is now and titled as the page titles it. The pin is the
  # agent's person's, so a person's pins and their agents' are one set.
  def pin(conn, %{"fleet_id" => fleet_id, "project" => name, "place" => place} = params) do
    actor = conn.assigns.agent_actor
    place = String.to_existing_atom(place)

    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, projects} <- Projects.projects(fleet_id, actor: actor),
         {:ok, %{^name => project}} <- shown(projects, name),
         {:ok, title, folder?} <- pinned(fleet_id, project, place, params["target"]),
         {:ok, pin} <-
           Graph.pin(
             %{
               fleet_id: fleet_id,
               project: name,
               place: place,
               target: params["target"],
               title: title,
               folder?: folder?
             },
             actor: actor
           ) do
      json(conn, %{pin: pin_json(pin)})
    else
      {:ok, nil} -> answer(conn, WorkspaceRefusal.refusal(404, "fleet_unknown"))
      :unknown -> answer(conn, WorkspaceRefusal.refusal(404, "project_unknown"))
      :not_there -> answer(conn, WorkspaceRefusal.refusal(404, "pin_target_unknown"))
      {:unreadable, :docs} -> answer(conn, WorkspaceRefusal.refusal(503, "notebooks_unavailable"))
      {:unreadable, :code} -> answer(conn, WorkspaceRefusal.refusal(503, "code_unavailable"))
      result -> pin_refused(result, conn, fleet_id)
    end
  end

  # Lifting a pin, which only its pinner does, as on the page.
  def unpin(conn, %{"fleet_id" => fleet_id, "project" => name, "place" => place} = params) do
    actor = conn.assigns.agent_actor

    with {:ok, pins} <- Graph.pins(fleet_id, String.to_existing_atom(place), name, actor: actor),
         {:pin, %{} = pin} <- {:pin, Enum.find(pins, &(&1.target == params["target"]))},
         {:yours, true} <- {:yours, pin.human_account_id == actor.human_account_id},
         :ok <- Graph.unpin(pin, actor: actor) do
      json(conn, %{unpinned: pin_json(pin)})
    else
      {:pin, nil} -> answer(conn, WorkspaceRefusal.refusal(404, "pin_unknown"))
      {:yours, false} -> answer(conn, WorkspaceRefusal.refusal(403, "pin_not_yours"))
      result -> pin_refused(result, conn, fleet_id)
    end
  end

  # What a pin names, as the project holds it now: a notebook by its id,
  # titled as the hub titles it, or a file or folder by its path, titled by
  # that path.
  defp pinned(fleet_id, %{hub_project_id: space}, :docs, id) when is_binary(space) do
    if Notebooks.hub?(fleet_id) do
      case HubClient.notebook(fleet_id, space, id) do
        {:ok, %{"title" => title}} -> {:ok, title, false}
        {:ok, nil} -> :not_there
        {:error, _error} -> {:unreadable, :docs}
      end
    else
      :not_there
    end
  end

  defp pinned(_fleet_id, _project, :docs, _id), do: :not_there

  defp pinned(_fleet_id, %{repository: repository}, :code, path) do
    {parents, [name]} = path |> String.split("/") |> Enum.split(-1)

    if Enum.any?([name | parents], &(&1 in ["", ".", ".."])),
      do: :not_there,
      else: in_folder(repository, Enum.join(parents, "/"), name, path)
  end

  defp in_folder(repository, folder, name, path) do
    case Code.folder(repository, folder) do
      {:ok, entries} ->
        case Enum.find(entries, &(&1.name == name)) do
          nil -> :not_there
          entry -> {:ok, path, entry.folder?}
        end

      {:error, _error} ->
        {:unreadable, :code}
    end
  end

  defp pin_json(pin),
    do: %{
      project: pin.project,
      place: pin.place,
      target: pin.target,
      title: pin.title,
      folder: pin.folder?
    }

  # Only the fleet's members pin in its workspace, and who they are can't be
  # read while the fleet's key ownership is not fresh.
  defp pin_refused({:error, %Ash.Error.Forbidden{}}, conn, fleet_id) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: answer(conn, WorkspaceRefusal.refusal(403, "workspace_members_only")),
      else: answer(conn, WorkspaceRefusal.refusal(503, "ownership_refreshing"))
  end

  defp pin_refused({:error, error}, conn, _fleet_id), do: refuse(conn, error)

  defp shown(projects, nil), do: {:ok, Map.new(projects, &{&1.name, &1})}

  defp shown(projects, name) do
    case Enum.find(projects, &(&1.name == name)) do
      nil -> :unknown
      project -> {:ok, %{name => project}}
    end

  defp answer_read(conn, {:ok, answer}), do: json(conn, answer)
  defp answer_read(conn, {:error, error}), do: refuse(conn, error)

  # A write past its wallet's allowance in the fleet
  # (`Keyfleet.Graph.Validations.WriteAllowance`) says when to try again.
  defp write(conn, action, %{"fleet_id" => fleet_id} = params, fields) do
    input = Map.take(params, @command ++ fields)

    case action.(fleet_id, input, actor: conn.assigns.agent_actor) do
      {:ok, written} -> json(conn, written)
      {:error, error} -> conn |> retry_after(error) |> refuse(error)
    end
  end

  defp retry_after(conn, %{errors: errors}) do
    case Enum.find(errors, &match?(%WriteLimitError{}, &1)) do
      %WriteLimitError{retry_after: seconds} ->
        put_resp_header(conn, "retry-after", Integer.to_string(seconds))

      nil ->
        conn
    end
  end

  defp refuse(conn, %{errors: errors} = error),
    do: answer(conn, Enum.find_value(errors, &WorkspaceRefusal.for_error/1) || fallback(error))

  defp answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  # The policy's own refusal, before the write took its turn.
  defp fallback(%Ash.Error.Forbidden{}), do: WorkspaceRefusal.refusal(403, "not_a_key_holder")
  defp fallback(%Ash.Error.Invalid{}), do: WorkspaceRefusal.refusal(422, "invalid_request")
end
