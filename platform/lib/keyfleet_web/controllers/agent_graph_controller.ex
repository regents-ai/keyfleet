defmodule KeyfleetWeb.AgentGraphController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets, Graph, Notebooks, Projects, Rooms}
  alias Keyfleet.Graph.Errors.WriteLimitError
  alias KeyfleetWeb.{Endpoint, RoomJSON, WorkspacePage, WorkspaceRefusal}

  @command ~w(as_key command_id)

  # As many goals as the workspace reads in one page.
  @board_goals 24

  # The workspace's graph as its Graph view draws it: the items, the links
  # between them and the Keys that own them, with the page's filters, each
  # item with its page's address.
  def view(conn, %{"fleet_id" => fleet_id} = params) do
    opts = [actor: conn.assigns.agent_actor]
    filter = Map.take(params, ~w(project type owner_key archived))

    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, projects} <- Projects.projects(fleet_id, opts),
         {:ok, _shown} <- shown(projects, params["project"]),
         {:ok, graph} <- Graph.workspace_graph(fleet_id, filter, opts) do
      json(
        conn,
        Map.update!(graph, :nodes, fn nodes -> Enum.map(nodes, &graph_node(&1, fleet_id)) end)
      )
    else
      {:ok, nil} -> answer(conn, refusal(404, "fleet_unknown"))
      :unknown -> answer(conn, refusal(404, "project_unknown"))
      result -> read(result, conn, fleet_id)
    end
  end

  # One item as its page in the workspace shows it, in one read: the item,
  # its links and the items at their other ends, its page's address, the posts
  # its discussion names and, for a task, the commit to clone and what its
  # rerun is missing. `fields` names the parts besides the item to answer;
  # the posts its discussion names are read only when it names them.
  def get_object(conn, %{"fleet_id" => fleet_id, "id" => id} = params) do
    actor = conn.assigns.agent_actor
    parts = parts(params)

    result =
      with {:ok, read} <-
             Graph.get_object(fleet_id, id, Map.take(params, ~w(relations_after)), actor: actor),
           do:
             {:ok,
              read |> Map.merge(around(read.object, fleet_id, actor, parts)) |> Map.take(parts)}

    read(result, conn, fleet_id)
  end

  @parts ~w(owner_key relations linked url discussion commit rerun_check agents)a

  # The item and how far the workspace had read are always answered; a page
  # of links comes with the place to read on from.
  defp parts(%{"fields" => fields}) do
    named = fields |> String.split(",") |> Enum.map(&String.to_existing_atom/1)

    [:object, :watermark | named] ++
      if(:relations in named, do: [:relations_next_cursor], else: [])
  end

  defp parts(_params), do: [:object, :watermark, :relations_next_cursor | @parts]

  def changes(conn, %{"fleet_id" => fleet_id} = params) do
    fleet_id
    |> Graph.list_changes(Map.take(params, ~w(after_seq limit project object max_bytes)),
      actor: conn.assigns.agent_actor
    )
    |> read(conn, fleet_id)
  end

  # What the workspace's pages keep at hand, the whole fleet's or one
  # project's: its newest goals, as its Project lists them, and what its
  # members pinned in its Docs and its Code.
  def board(conn, %{"fleet_id" => fleet_id} = params) do
    opts = [actor: conn.assigns.agent_actor]
    project = params["project"]

    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, projects} <- Projects.projects(fleet_id, opts),
         {:ok, shown} <- shown(projects, project),
         {:ok, goals} <-
           Graph.workspace_cards(
             fleet_id,
             %{type: "goal", project: project},
             Keyword.put(opts, :page, limit: @board_goals)
           ),
         {:ok, notebooks} <- Graph.pins(fleet_id, :docs, project, opts),
         {:ok, code} <- Graph.pins(fleet_id, :code, project, opts) do
      json(conn, %{
        goals: Enum.map(goals.results, &goal(&1, fleet_id)),
        more_goals: goals.more?,
        pinned_notebooks:
          for pin <- notebooks do
            space = if Notebooks.hub?(fleet_id), do: shown[pin.project].hub_project_id

            %{
              project: pin.project,
              notebook_id: pin.target,
              title: pin.title,
              notebook_url: space && Notebooks.notebook_url(fleet_id, space, pin.target)
            }
          end,
        pinned_code:
          for pin <- code do
            repository = shown[pin.project].repository

            %{
              project: pin.project,
              path: pin.target,
              title: pin.title,
              folder: pin.folder?,
              url: Endpoint.url() <> Code.files_path(fleet_id, repository, pin.target)
            }
          end
      })
    else
      {:ok, nil} -> answer(conn, refusal(404, "fleet_unknown"))
      :unknown -> answer(conn, refusal(404, "project_unknown"))
      result -> read(result, conn, fleet_id)
    end
  end

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

  defp read({:ok, result}, conn, _fleet_id), do: json(conn, result)

  # Only the fleet's members read its workspace, and who they are can't be
  # read while the fleet's key ownership is not fresh.
  defp read({:error, %Ash.Error.Forbidden{}}, conn, fleet_id) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: answer(conn, refusal(403, "workspace_members_only")),
      else: answer(conn, refusal(503, "ownership_refreshing"))
  end

  defp read({:error, %Ash.Error.Unknown{errors: errors} = error}, conn, _fleet_id),
    do: answer(conn, Enum.find_value(errors, &WorkspaceRefusal.for_error/1) || unreadable(error))

  defp read({:error, error}, conn, _fleet_id), do: refuse(conn, error)

  # A read that failed some other way, such as the database not answering.
  # Nothing was written, so the workspace is answered as unavailable, and the
  # failure is saved with the site's errors beside the answer, which never
  # waits on the save, so one that keeps failing is seen at /admin/errors.
  defp unreadable(error) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    context = ErrorTracker.get_context()

    Task.Supervisor.start_child(Keyfleet.ErrorSaves, fn ->
      Keyfleet.Alert.save(error, Enum.drop(stacktrace, 1), context)
    end)

    refusal(503, "graph_unavailable")
  end

  defp around(object, fleet_id, actor, parts) do
    %{
      url: fn -> Endpoint.url() <> WorkspacePage.item_path(fleet_id, object.id) end,
      discussion: fn -> discussion(object.data["discussion"], fleet_id, actor) end,
      commit: fn -> commit(object.data["commit_ref"], fleet_id) end
    }
    |> Map.take(parts)
    |> Map.new(fn {part, read} -> {part, read.()} end)
  end

  # Each post the item's discussion names, as a room read answers it: nil for
  # one the agent can't read there, such as a post by a Key it muted, or a
  # place the room has no post at.
  defp discussion(links, fleet_id, actor) when is_list(links) and links != [] do
    muted = Rooms.muted_keys!(fleet_id, actor)

    for %{"room" => room, "seq" => seq} <- links do
      %{room: room, seq: seq, post: post(fleet_id, room, seq, muted, actor)}
    end
  end

  defp discussion(_links, _fleet_id, _actor), do: []

  defp post(fleet_id, room, seq, muted, actor) do
    case Rooms.read_messages(fleet_id, room, %{after_seq: seq - 1, limit: 1}, actor: actor) do
      {:ok, [%{seq: ^seq} = message]} ->
        case Rooms.unmuted([message], muted) do
          [shown] -> RoomJSON.message(shown)
          [] -> nil
        end

      _other ->
        nil
    end
  end

  # A commit of one of the fleet's own repositories, with the address its
  # agent clones it from.
  defp commit(uri, fleet_id) do
    with {repository, hash} <- WorkspacePage.fleet_commit(uri, fleet_id) do
      %{repository: repository, hash: hash, clone_url: Code.agent_clone_url(repository)}
    end
  end

  defp graph_node(node, fleet_id),
    do: Map.put(node, :url, Endpoint.url() <> WorkspacePage.item_path(fleet_id, node.id))

  defp goal(object, fleet_id) do
    %{
      id: object.id,
      project: object.project,
      title: object.title,
      status: object.card["status"],
      starting: is_integer(object.sys["starting"]),
      joined: length(Map.get(object.sys, "joined", [])),
      changed_at: object.changed_at,
      url: Endpoint.url() <> WorkspacePage.item_path(fleet_id, object.id)
    }
  end

  # The projects a board shows, by name: the one asked for, or every one.
  defp shown(projects, nil), do: {:ok, Map.new(projects, &{&1.name, &1})}

  defp shown(projects, name) do
    case Enum.find(projects, &(&1.name == name)) do
      nil -> :unknown
      project -> {:ok, %{name => project}}
    end
  end

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
  defp fallback(%Ash.Error.Forbidden{}), do: refusal(403, "not_a_key_holder")
  defp fallback(%Ash.Error.Invalid{}), do: refusal(422, "invalid_request")

  defp refusal(status, code, details \\ %{}), do: WorkspaceRefusal.refusal(status, code, details)
end
