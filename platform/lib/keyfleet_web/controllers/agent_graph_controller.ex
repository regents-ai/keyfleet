defmodule KeyFleetWeb.AgentGraphController do
  use KeyFleetWeb, :controller

  alias KeyFleet.Graph
  alias KeyFleet.Graph.Errors.IndeterminateError
  alias KeyFleet.Graph.Errors.NotKeyHolderError
  alias KeyFleet.Graph.Errors.RefusedError
  alias KeyFleet.Graph.Errors.UnavailableError
  alias KeyFleet.Graph.Errors.UnknownFleetError
  alias KeyFleet.Keys.Errors.OwnershipRefreshingError

  # The graph's own refusals, by the status each is answered with.
  @refusal_statuses %{
    "bad_request" => 400,
    "forbidden_scope" => 403,
    "not_found" => 404,
    "conflict" => 409,
    "invalid" => 422,
    "forbidden_field" => 422,
    "duplicate_mismatch" => 422
  }

  @command ~w(as_key command_id)

  def get_object(conn, %{"fleet_id" => fleet_id, "id" => id}) do
    fleet_id |> Graph.get_object(id, actor: conn.assigns.agent_actor) |> read(conn)
  end

  def changes(conn, %{"fleet_id" => fleet_id} = params) do
    fleet_id
    |> Graph.list_changes(Map.take(params, ~w(after_seq limit)), actor: conn.assigns.agent_actor)
    |> read(conn)
  end

  def create(conn, params), do: write(conn, &Graph.create_object/3, params, ~w(type scope data))

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

  defp read({:ok, result}, conn), do: json(conn, result)
  defp read({:error, error}, conn), do: refuse(conn, error)

  defp write(conn, action, %{"fleet_id" => fleet_id} = params, fields) do
    case action.(fleet_id, Map.take(params, @command ++ fields), actor: conn.assigns.agent_actor) do
      {:ok, written} -> json(conn, written)
      {:error, error} -> refuse(conn, error)
    end
  end

  defp refuse(conn, %{errors: errors} = error) do
    {status, code, message, details} =
      Enum.find_value(errors, &answer/1) || fallback(error)

    conn
    |> put_status(status)
    |> json(%{error: code, message: message, details: details})
  end

  defp answer(%RefusedError{code: code, reason: reason, details: details}),
    do: {Map.fetch!(@refusal_statuses, code), code, reason, details}

  defp answer(%UnknownFleetError{} = error),
    do: {404, "fleet_unknown", Exception.message(error), %{}}

  defp answer(%OwnershipRefreshingError{} = error),
    do: {503, "ownership_refreshing", Exception.message(error), %{}}

  defp answer(%NotKeyHolderError{} = error),
    do: {403, "not_a_key_holder", Exception.message(error), %{}}

  defp answer(%UnavailableError{} = error),
    do: {503, "graph_unavailable", Exception.message(error), %{}}

  defp answer(%IndeterminateError{} = error),
    do:
      {503, "indeterminate", Exception.message(error) <> "; retry with the same command id",
       %{retry_same_command_id: true}}

  defp answer(_error), do: nil

  # The policy's own refusal, before the write took its turn.
  defp fallback(%Ash.Error.Forbidden{}),
    do: {403, "not_a_key_holder", "this wallet does not own or run that key today", %{}}

  defp fallback(%Ash.Error.Invalid{}),
    do: {422, "invalid_request", "the request does not fit this operation", %{}}
end
