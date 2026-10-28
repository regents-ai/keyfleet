defmodule KeyfleetWeb.AgentGraphController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets, Graph, Notebooks, Projects}
  alias Keyfleet.Graph.Errors.EditsRestrictedError
  alias Keyfleet.Graph.Errors.IndeterminateError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Errors.UnavailableError
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Limits
  alias Keyfleet.Projects.Errors.UnknownProjectError
  alias KeyfleetWeb.{Endpoint, Refusal, WorkspacePage}

  # The workspace's own refusals: the status each is answered with, and what
  # to do next. The workspace's reason is the message.
  @workspace_refusals %{
    "bad_request" =>
      {400, "The body doesn't fit this operation. Check it against the docs, then send it again."},
    "not_found" =>
      {404,
       "Check the id: an item's id is its type, `#` and its number, such as `task#27`. The workspace's changes (`workspace changes` on the command line) list everything it holds."},
    "conflict" =>
      {409,
       "details.object is the item as it is now. Merge your change into it, then send it with its version and a new command_id."},
    "invalid" => {422, "Correct the value the message names, then send the request again."},
    "forbidden_field" =>
      {422,
       "Leave out the fields details.fields names. details.allowed, when present, lists the fields this kind of item takes; a task is marked done by submitting it, and a task another Key holds is forked rather than taken."},
    "not_owner" =>
      {403,
       "Fork a task to work on it as your own, or link your own item to this one. details.owner_key names the Key it belongs to."},
    "self_review" =>
      {403,
       "Ask a member who did not submit the task, from another Key and wallet, to review it."},
    "duplicate_mismatch" =>
      {422, "This command_id was used for a different change. Use a new command_id."}
  }

  @command ~w(as_key command_id)

  # As many goals as the workspace reads in one page.
  @board_goals 24

  def get_object(conn, %{"fleet_id" => fleet_id, "id" => id} = params) do
    fleet_id
    |> Graph.get_object(id, Map.take(params, ~w(relations_after)),
      actor: conn.assigns.agent_actor
    )
    |> read(conn, fleet_id)
  end

  def changes(conn, %{"fleet_id" => fleet_id} = params) do
    fleet_id
    |> Graph.list_changes(Map.take(params, ~w(after_seq limit project)),
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
    do: answer(conn, Enum.find_value(errors, &answer/1) || unreadable(error))

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

  # Each wallet has its own allowance of writes in each fleet, spent before
  # the write takes the fleet's one writer. It is kept by wallet, not by the
  # Key a write names: that Key is checked only later, so anyone could spend
  # another Key's allowance by naming it.
  defp write(conn, action, %{"fleet_id" => fleet_id} = params, fields) do
    actor = conn.assigns.agent_actor
    input = Map.take(params, @command ++ fields)

    with :ok <- Limits.admit(:graph_writes, {fleet_id, actor.wallet_address}),
         {:ok, written} <- action.(fleet_id, input, actor: actor) do
      json(conn, written)
    else
      {:limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> answer(refusal(429, "workspace_limit_reached"))

      {:error, error} ->
        refuse(conn, error)
    end
  end

  # Every refusal here carries `details`, empty unless it says more.
  defp refuse(conn, %{errors: errors} = error),
    do: answer(conn, Enum.find_value(errors, &answer/1) || fallback(error))

  defp answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  defp answer(%RefusedError{code: code, reason: reason, details: details})
       when code in ~w(project_archived project_unknown),
       do: {project_status(code), Refusal.closed(code, reason, details)}

  defp answer(%RefusedError{code: code, reason: reason, details: details}) do
    {status, hint} = Map.fetch!(@workspace_refusals, code)
    {status, %{error: %{code: code, message: reason, hint: hint, details: details}}}
  end

  defp answer(%UnknownFleetError{}), do: refusal(404, "fleet_unknown")
  defp answer(%UnknownProjectError{}), do: refusal(404, "project_unknown")
  defp answer(%OwnershipRefreshingError{}), do: refusal(503, "ownership_refreshing")
  defp answer(%NotKeyHolderError{}), do: refusal(403, "not_a_key_holder")
  defp answer(%EditsRestrictedError{}), do: refusal(403, "edits_restricted")
  defp answer(%UnavailableError{}), do: refusal(503, "graph_unavailable")

  defp answer(%IndeterminateError{}),
    do: refusal(503, "indeterminate", %{retry_same_command_id: true})

  defp answer(_error), do: nil

  defp project_status("project_archived"), do: 409
  defp project_status("project_unknown"), do: 404

  # The policy's own refusal, before the write took its turn.
  defp fallback(%Ash.Error.Forbidden{}), do: refusal(403, "not_a_key_holder")
  defp fallback(%Ash.Error.Invalid{}), do: refusal(422, "invalid_request")

  defp refusal(status, code, details \\ %{}),
    do: {status, put_in(Refusal.body(code), [:error, :details], details)}
end
