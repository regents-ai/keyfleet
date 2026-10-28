defmodule KeyfleetWeb.AgentProjectController do
  @moduledoc """
  A fleet's projects, for an agent through its own signed requests: list
  them, active ones first, with which one the agent's own Key works on; and,
  as a Key, start, archive, take over and delete one, and give one it holds
  its one-line description (`Keyfleet.Projects`).
  New work goes into any active project, whoever holds it.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets, Keys, Projects}
  alias Keyfleet.Graph.Errors.{CheckExpiredError, EditsRestrictedError}
  alias Keyfleet.Graph.Errors.{NotKeyHolderError, UnknownFleetError}
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Projects.Errors.{HoldError, NameTakenError, UnknownProjectError}
  alias KeyfleetWeb.Refusal

  def index(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor

    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, projects} <- Projects.by_state(fleet_id, actor: actor) do
      key = with %{token_id: token_id} <- Keys.identity(actor, fleet_id), do: token_id
      yours = Enum.find(projects, &(&1.state == :active and &1.key == key))

      json(conn, %{
        your_key: key,
        your_project: yours && yours.name,
        projects: Enum.map(projects, &project(&1, yours))
      })
    else
      {:ok, nil} -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, error} -> refuse(conn, fleet_id, error)
    end
  end

  def start(conn, %{"fleet_id" => fleet_id, "as_key" => key, "name" => name, "title" => title}),
    do: held(conn, fleet_id, &Projects.start_project(fleet_id, key, name, title, &1))

  def archive(conn, %{"fleet_id" => fleet_id, "as_key" => key}),
    do: held(conn, fleet_id, &Projects.archive_project(fleet_id, key, &1))

  def take_over(conn, %{"fleet_id" => fleet_id, "project" => name, "as_key" => key}),
    do: held(conn, fleet_id, &Projects.take_over_project(fleet_id, key, name, &1))

  def delete(conn, %{"fleet_id" => fleet_id, "project" => name, "as_key" => key}),
    do: held(conn, fleet_id, &Projects.delete_project(fleet_id, key, name, &1))

  # null or an empty line takes the description away.
  def describe(conn, %{
        "fleet_id" => fleet_id,
        "project" => name,
        "as_key" => key,
        "description" => line
      }),
      do: held(conn, fleet_id, &Projects.describe_project(fleet_id, key, name, line, &1))

  defp held(conn, fleet_id, step) do
    case step.(actor: conn.assigns.agent_actor) do
      {:ok, project} -> json(conn, %{project: project(project, nil)})
      {:error, error} -> refuse(conn, fleet_id, error)
    end
  end

  defp project(project, yours) do
    %{
      name: project.name,
      title: project.title,
      description: project.description,
      key: project.key,
      state: project.state,
      yours: yours != nil and project.name == yours.name,
      clone_url: Code.agent_clone_url(project.repository)
    }
  end

  defp refuse(conn, fleet_id, %Ash.Error.Forbidden{}) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, "not_a_key_holder"),
      else: Refusal.json(conn, 503, "ownership_refreshing")
  end

  defp refuse(conn, _fleet_id, %{errors: errors}) do
    {status, body} = Enum.find_value(errors, &answer/1) || {422, Refusal.body("project_invalid")}
    conn |> put_status(status) |> json(body)
  end

  defp answer(%HoldError{code: code, words: words}) do
    code = "project_#{code}"
    status = if code == "project_not_holder", do: 403, else: 409
    {status, put_in(Refusal.body(code), [:error, :message], words)}
  end

  defp answer(%NameTakenError{} = error),
    do:
      {409,
       put_in(Refusal.body("project_name_taken"), [:error, :message], Exception.message(error))}

  defp answer(%UnknownProjectError{}), do: {404, Refusal.body("project_unknown")}
  defp answer(%UnknownFleetError{}), do: {404, Refusal.body("fleet_unknown")}
  defp answer(%OwnershipRefreshingError{}), do: {503, Refusal.body("ownership_refreshing")}
  defp answer(%NotKeyHolderError{}), do: {403, Refusal.body("not_a_key_holder")}
  defp answer(%EditsRestrictedError{}), do: {403, Refusal.body("edits_restricted")}
  defp answer(%CheckExpiredError{}), do: {503, Refusal.body("graph_unavailable")}
  defp answer(_error), do: nil
end
