defmodule KeyfleetWeb.AgentNotebookController do
  @moduledoc """
  A fleet's notebooks and their runs, for an agent through its own signed
  requests to this site: list the notebooks, each with the last run an agent
  started there, start a background run of a notebook's saved code, then
  read it until it has finished and its saved result has an address the
  workspace can cite (`Keyfleet.Notebooks.Runs`). The agent is let in exactly
  as on the fleet's notebook host (`Keyfleet.Notebooks.admit/3`), and the hub
  knows each run as the agent's. Starting a run spends the agent's
  `:notebook_run_starts` allowance, the same one the notebook host spends.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Limits
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.Runs
  alias KeyfleetWeb.Refusal

  def index(conn, %{"fleet_id" => fleet_id}) do
    in_notebooks(conn, fleet_id, fn subject, project_id ->
      with {:ok, notebooks} <- Runs.list(fleet_id, subject, project_id),
           do: {:ok, %{notebooks: notebooks}}
    end)
  end

  def start(conn, %{
        "fleet_id" => fleet_id,
        "notebook_id" => notebook_id,
        "idempotency_key" => idempotency_key
      }) do
    in_notebooks(conn, fleet_id, fn subject, project_id ->
      with :ok <- Limits.admit(:notebook_run_starts, subject),
           do: Runs.start(fleet_id, subject, project_id, notebook_id, idempotency_key)
    end)
  end

  def show(conn, %{"fleet_id" => fleet_id, "notebook_id" => notebook_id, "run_id" => run_id}) do
    in_notebooks(conn, fleet_id, fn subject, project_id ->
      Runs.read(fleet_id, subject, project_id, notebook_id, run_id)
    end)
  end

  defp in_notebooks(conn, fleet_id, act) do
    actor = conn.assigns.agent_actor

    with {:hub, true} <- {:hub, Notebooks.hub?(fleet_id)},
         {:profile, {:ok, subject}} when is_binary(subject) <-
           {:profile, Notebooks.agent(actor)},
         {:ok, project_id} <- Notebooks.admit(actor, fleet_id, subject),
         {:ok, answer} <- act.(subject, project_id) do
      json(conn, answer)
    else
      {:hub, false} -> Refusal.json(conn, 404, "notebooks_not_found")
      {:profile, {:ok, nil}} -> Refusal.json(conn, 403, "notebooks_agent_profile")
      {:profile, {:error, _error}} -> Refusal.json(conn, 503, "notebooks_unavailable")
      {:error, :not_holder} -> Refusal.json(conn, 403, "notebooks_not_holder")
      {:error, :not_found} -> Refusal.json(conn, 404, "notebook_run_not_found")
      {:error, :runs_full} -> Refusal.json(conn, 429, "notebook_runs_full")
      {:error, :catching_up} -> Refusal.json(conn, 503, "notebooks_catching_up")
      {:error, :setting_up} -> Refusal.json(conn, 503, "notebooks_setting_up")
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
end
