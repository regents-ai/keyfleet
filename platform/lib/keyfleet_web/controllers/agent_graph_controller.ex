defmodule KeyfleetWeb.AgentGraphController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.WriteLimitError
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
