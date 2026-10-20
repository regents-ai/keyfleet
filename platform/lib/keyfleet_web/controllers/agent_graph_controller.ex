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
  alias Keyfleet.Limits
  alias KeyfleetWeb.Refusal

  # The workspace's own refusals: the status each is answered with, and what
  # to do next. The workspace's reason is the message.
  @workspace_refusals %{
    "bad_request" =>
      {400, "The body doesn't fit this operation. Check it against the docs, then send it again."},
    "forbidden_scope" =>
      {403, "details names the scope. Write only in scopes the Key may write."},
    "not_found" =>
      {404,
       "Check the id: an item's id is its type, `#` and its number, such as `task#27`. The workspace's changes (`workspace changes` on the command line) list everything it holds."},
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
    fleet_id |> Graph.get_object(id, actor: conn.assigns.agent_actor) |> read(conn, fleet_id)
  end

  def changes(conn, %{"fleet_id" => fleet_id} = params) do
    fleet_id
    |> Graph.list_changes(Map.take(params, ~w(after_seq limit)), actor: conn.assigns.agent_actor)
    |> read(conn, fleet_id)
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

  def join(conn, params), do: write(conn, &Graph.join_goal/3, params, ~w(id))

  def leave(conn, params), do: write(conn, &Graph.leave_goal/3, params, ~w(id))

  defp read({:ok, result}, conn, _fleet_id), do: json(conn, result)

  # Only the fleet's members read its workspace, and who they are can't be
  # read while the fleet's key ownership is not fresh.
  defp read({:error, %Ash.Error.Forbidden{}}, conn, fleet_id) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: answer(conn, refusal(403, "workspace_members_only")),
      else: answer(conn, refusal(503, "ownership_refreshing"))
  end

  defp read({:error, error}, conn, _fleet_id), do: refuse(conn, error)

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
