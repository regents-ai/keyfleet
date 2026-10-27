defmodule KeyfleetWeb.AgentNotebookController do
  @moduledoc """
  A fleet's notebooks and their runs, for an agent through its own signed
  requests to this site: list the notebooks, each with the last run an agent
  started there, start a background run of a notebook's saved code, then
  read it until it has finished and its saved result has an address the
  workspace can cite (`Keyfleet.Notebooks.Runs`); and make a notebook, then
  list, read, add and write its files (`Keyfleet.Notebooks.Files`), each in
  the space of the project the address names. The agent is let in exactly
  as on the fleet's notebook host (`Keyfleet.Notebooks.admit/3`), and the hub
  knows each run, notebook and change as the agent's. An archived project's
  notebooks are read and never changed, and a Key whose edits a vote of the
  fleet has restricted lists and reads, and starts, makes and writes nothing. Starting a run spends the agent's
  `:notebook_run_starts` allowance, the same one the notebook host spends.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Limits
  alias Keyfleet.{Notebooks, Projects}
  alias Keyfleet.Notebooks.{Files, Runs}
  alias Keyfleet.Projects.Errors.ClosedError
  alias KeyfleetWeb.Refusal

  def index(conn, %{"fleet_id" => fleet_id, "project" => project}) do
    in_notebooks(conn, fleet_id, project, :read, fn subject, space ->
      with {:ok, notebooks} <- Runs.list(fleet_id, subject, space),
           do: {:ok, %{notebooks: notebooks}}
    end)
  end

  def start(conn, %{
        "fleet_id" => fleet_id,
        "project" => project,
        "notebook_id" => notebook_id,
        "idempotency_key" => idempotency_key
      }) do
    in_notebooks(conn, fleet_id, project, :change, fn subject, space ->
      with :ok <- Limits.admit(:notebook_run_starts, subject),
           do: Runs.start(fleet_id, subject, space, notebook_id, idempotency_key)
    end)
  end

  def show(conn, %{
        "fleet_id" => fleet_id,
        "project" => project,
        "notebook_id" => notebook_id,
        "run_id" => run_id
      }) do
    in_notebooks(conn, fleet_id, project, :read, fn subject, space ->
      Runs.read(fleet_id, subject, space, notebook_id, run_id)
    end)
  end

  def create(
        conn,
        %{"fleet_id" => fleet_id, "project" => project, "idempotency_key" => idempotency_key} =
          params
      ) do
    in_notebooks(conn, fleet_id, project, :change, fn subject, space ->
      notebook =
        params
        |> Map.take(~w(title code description))
        |> Map.put("tags", tags(params["goal"], params["folder"]))

      fleet_id
      |> Files.create(subject, space, notebook, idempotency_key)
      |> edited(conn, fleet_id)
    end)
  end

  def list_files(
        conn,
        %{"fleet_id" => fleet_id, "project" => project, "notebook_id" => notebook_id} = params
      ) do
    in_notebooks(conn, fleet_id, project, :read, fn subject, space ->
      Files.list(fleet_id, subject, space, notebook_id, params["path"], params["cursor"])
    end)
  end

  def read_file(conn, %{
        "fleet_id" => fleet_id,
        "project" => project,
        "notebook_id" => notebook_id,
        "path" => path
      }) do
    in_notebooks(conn, fleet_id, project, :read, fn subject, space ->
      Files.read(fleet_id, subject, space, notebook_id, path)
    end)
  end

  def add_file(conn, params), do: write(conn, params, :add)
  def write_file(conn, params), do: write(conn, params, :write)

  defp write(
         conn,
         %{
           "fleet_id" => fleet_id,
           "project" => project,
           "notebook_id" => notebook_id,
           "path" => path,
           "content" => content
         },
         mode
       ) do
    in_notebooks(conn, fleet_id, project, :change, fn subject, space ->
      fleet_id
      |> Files.write(subject, space, notebook_id, path, content, mode)
      |> edited(conn, fleet_id)
    end)
  end

  # A notebook made or a file written is the agent's latest contribution.
  defp edited({:ok, _answer} = made, conn, fleet_id) do
    Keyfleet.Agents.record_contribution(conn.assigns.agent_actor, fleet_id, :notebook)
    made
  end

  defp edited(refused, _conn, _fleet_id), do: refused

  # A Key whose edits a vote of the fleet has restricted only reads, and so
  # does anyone in an archived project. Only a member learns which projects
  # the fleet has.
  defp in_notebooks(conn, fleet_id, project, need, act) do
    actor = conn.assigns.agent_actor

    with {:hub, true} <- {:hub, Notebooks.hub?(fleet_id)},
         {:profile, {:ok, subject}} when is_binary(subject) <-
           {:profile, Notebooks.agent(actor)},
         {:ok, access} <- Notebooks.admit(actor, fleet_id, subject),
         {:restricted, false} <- {:restricted, need == :change and access.restricted?},
         :ok <- usable(fleet_id, project, need),
         {:space, space} when is_binary(space) <- {:space, access.spaces[project]},
         {:ok, answer} <- act.(subject, space) do
      json(conn, answer)
    else
      {:hub, false} -> Refusal.json(conn, 404, "notebooks_not_found")
      %ClosedError{} = closed -> closed(conn, closed)
      {:restricted, true} -> Refusal.json(conn, 403, "notebooks_edits_restricted")
      {:error, :not_maker} -> Refusal.json(conn, 403, "notebooks_maker_only")
      {:profile, {:ok, nil}} -> Refusal.json(conn, 403, "notebooks_agent_profile")
      {:profile, {:error, _error}} -> Refusal.json(conn, 503, "notebooks_unavailable")
      {:error, :not_holder} -> Refusal.json(conn, 403, "notebooks_not_holder")
      {:error, :not_found} -> Refusal.json(conn, 404, "notebook_run_not_found")
      {:error, :runs_full} -> Refusal.json(conn, 429, "notebook_runs_full")
      {:error, :file_not_found} -> Refusal.json(conn, 404, "notebook_file_not_found")
      {:error, :conflict} -> Refusal.json(conn, 409, "notebook_file_conflict")
      {:error, :refused} -> Refusal.json(conn, 422, "notebook_file_refused")
      {:error, :files_full} -> Refusal.json(conn, 422, "notebook_files_full")
      {:error, :too_large} -> Refusal.json(conn, 422, "notebook_file_too_large")
      {:error, :not_text} -> Refusal.json(conn, 422, "notebook_file_not_text")
      {:error, :catching_up} -> Refusal.json(conn, 503, "notebooks_catching_up")
      {:error, :setting_up} -> Refusal.json(conn, 503, "notebooks_setting_up")
      {:space, nil} -> Refusal.json(conn, 503, "notebooks_setting_up")
      {:error, :unavailable} -> Refusal.json(conn, 503, "notebooks_unavailable")
      {:limited, seconds} -> runs_limited(conn, seconds)
    end
  end

  # Runs started on the notebook host and here share one allowance.
  defp runs_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> Refusal.json(429, "notebook_runs_limit_reached")
  end

  # An archived project's notebooks are read, and only an active project's
  # changed.
  defp usable(fleet_id, project, need) do
    case Projects.open(fleet_id, project) do
      {:ok, _project} -> :ok
      {:error, %ClosedError{code: :project_archived}} when need == :read -> :ok
      {:error, closed} -> closed
    end
  end

  defp closed(conn, %ClosedError{code: code} = closed) do
    status = if code == :project_archived, do: 409, else: 404

    body =
      Refusal.closed(to_string(code), Exception.message(closed), %{
        project: closed.project,
        active: closed.active
      })

    conn |> put_status(status) |> json(body)
  end

  # A notebook made for goal#N carries the tag goal-N, which lists it on the
  # goal's page, and one made in a folder the tag folder/<name>, which the
  # project's Docs group it under.
  defp tags(goal, folder) do
    for {prefix, value} <- [{"goal-", goal_number(goal)}, {"folder/", folder}],
        value != nil,
        do: prefix <> value
  end

  defp goal_number(nil), do: nil
  defp goal_number("goal#" <> n), do: n
end
