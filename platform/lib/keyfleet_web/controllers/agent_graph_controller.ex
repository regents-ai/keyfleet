defmodule KeyfleetWeb.AgentGraphController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.EditsRestrictedError
  alias Keyfleet.Graph.Errors.IndeterminateError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Errors.UnavailableError
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias KeyfleetWeb.Refusal

  # The workspace's own refusals: the status each is answered with, and what
  # to do next. The workspace's reason is the message.
  @workspace_refusals %{
    "bad_request" =>
      {400, "The body doesn't fit this operation. Check it against the docs, then send it again."},
    "forbidden_scope" =>
      {403, "details names the scope. Write only in scopes the key may write."},
    "not_found" => {404, "Check the id. graph/changes lists what the workspace holds."},
    "conflict" =>
      {409,
       "details.object is the item as it is now. Merge your change into it, then send it with its version and a new command_id."},
    "invalid" => {422, "Correct the value the message names, then send the request again."},
    "forbidden_field" => {422, "Leave out the fields details names. Members may not set them."},
    "duplicate_mismatch" =>
      {422, "This command_id was used for a different change. Use a new command_id."}
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

  # Every refusal here carries `details`, empty unless it says more.
  defp refuse(conn, %{errors: errors} = error) do
    {status, body} = Enum.find_value(errors, &answer/1) || fallback(error)
    conn |> put_status(status) |> json(body)
  end

  defp answer(%RefusedError{code: code, reason: reason, details: details}) do
    {status, hint} = Map.fetch!(@workspace_refusals, code)
    {status, %{error: %{code: code, message: reason, hint: hint, details: details}}}
  end

  defp answer(%UnknownFleetError{}), do: refusal(404, "fleet_unknown")
  defp answer(%OwnershipRefreshingError{}), do: refusal(503, "ownership_refreshing")
  defp answer(%NotKeyHolderError{}), do: refusal(403, "not_a_key_holder")
  defp answer(%EditsRestrictedError{}), do: refusal(403, "edits_restricted")
  defp answer(%UnavailableError{}), do: refusal(503, "graph_unavailable")

  defp answer(%IndeterminateError{}),
    do: refusal(503, "indeterminate", %{retry_same_command_id: true})

  defp answer(_error), do: nil

  # The policy's own refusal, before the write took its turn.
  defp fallback(%Ash.Error.Forbidden{}), do: refusal(403, "not_a_key_holder")
  defp fallback(%Ash.Error.Invalid{}), do: refusal(422, "invalid_request")

  defp refusal(status, code, details \\ %{}),
    do: {status, put_in(Refusal.body(code), [:error, :details], details)}
end
