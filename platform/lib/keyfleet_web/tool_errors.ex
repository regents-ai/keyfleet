defmodule KeyfleetWeb.ToolErrors do
  @moduledoc """
  What a tool at the Claude connector's address (`/mcp`) says when its action
  refuses: the JSON the same refusal answers over HTTP,
  `{"error": {"code", "message", "hint"}}`, as the tool error's text
  (`AshAi.ToToolError`), with `retry_after` in seconds where HTTP sends
  `Retry-After`. A workspace refusal takes the workspace's words
  (`KeyfleetWeb.WorkspaceRefusal`), with its `details`. A connected app's
  identity refusal takes this site's own code and words, or, when no answer
  came, the words every Regent site gives it.

  Input a tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the router's `tool_argument_transformer`), as the action
  itself would refuse it, with the actor and context it would run with: a
  pairing's as `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), another identity tool's in the
  words every Regent site gives it, a fleet tool's with the refusal its signed
  request answers (an unknown fleet as `fleet_unknown`, say), or else as
  `invalid_request`. Input that is not an object, or names an input the
  action has not, is refused too. A write's allowance is spent only when it
  runs (`Keyfleet.Graph.Validations.WriteAllowance`), so checking spends none.
  """

  alias Keyfleet.Agents.Connection
  alias KeyfleetWeb.WorkspaceRefusal

  @doc """
  Casts a tool's `input` as its action takes it. Input it takes goes on to
  AshAi unchanged; other input is refused as `{:error, text}`.
  """
  @spec check_input(AshAi.Tool.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def check_input(%AshAi.Tool{resource: resource, action: %{name: action}}, arguments, context) do
    with %{} <- arguments,
         %{} = input <- arguments["input"] || %{},
         %{valid?: true} <-
           Ash.ActionInput.for_action(resource, action, input,
             actor: context[:actor],
             context: context[:context] || %{}
           ) do
      {:ok, arguments}
    else
      %Ash.ActionInput{errors: errors} -> {:error, refused(resource, action, errors)}
      _not_an_object -> {:error, refused(resource, action, [])}
    end
  end

  defp refused(Connection, :pair_identity, _errors),
    do: Jason.encode!(%{error: RegentMCPAgents.pairing_input_refusal()})

  defp refused(Connection, _identity, _errors), do: Jason.encode!(RegentMCPAgents.Tools.refusal())

  defp refused(_resource, _action, errors) do
    {_status, body} =
      Enum.find_value(errors, &WorkspaceRefusal.for_error/1) ||
        WorkspaceRefusal.refusal(422, "invalid_request")

    text(body)
  end

  @doc "`body` as a tool error's text, with `retry_after` in seconds when there is one."
  @spec text(map(), String.t() | integer() | nil) :: String.t()
  def text(%{error: error} = body, retry_after \\ nil),
    do: Jason.encode!(%{body | error: with_retry(error, retry_after)})

  defp with_retry(error, seconds) when is_integer(seconds),
    do: Map.put(error, :retry_after, seconds)

  defp with_retry(error, retry_after) when is_binary(retry_after) do
    case Integer.parse(retry_after) do
      {seconds, ""} -> Map.put(error, :retry_after, seconds)
      _not_seconds -> error
    end
  end

  defp with_retry(error, _none), do: error
end

defimpl AshAi.ToToolError, for: Keyfleet.Agents.Connection.Refused do
  def to_tool_error(%{error: %{} = error, retry_after: retry_after}),
    do: KeyfleetWeb.ToolErrors.text(%{error: error}, retry_after)

  def to_tool_error(_no_answer), do: Jason.encode!(RegentMCPAgents.Tools.refusal())
end

defimpl AshAi.ToToolError,
  for: [
    Keyfleet.Graph.Errors.RefusedError,
    Keyfleet.Graph.Errors.UnknownFleetError,
    Keyfleet.Graph.Errors.NotKeyHolderError,
    Keyfleet.Graph.Errors.EditsRestrictedError,
    Keyfleet.Graph.Errors.UnavailableError,
    Keyfleet.Graph.Errors.IndeterminateError,
    Keyfleet.Graph.Errors.MembersOnlyError,
    Keyfleet.Keys.Errors.OwnershipRefreshingError,
    Keyfleet.Projects.Errors.UnknownProjectError
  ] do
  def to_tool_error(error) do
    {_status, body} = KeyfleetWeb.WorkspaceRefusal.for_error(error)
    KeyfleetWeb.ToolErrors.text(body)
  end
end

defimpl AshAi.ToToolError, for: Keyfleet.Graph.Errors.WriteLimitError do
  def to_tool_error(%{retry_after: seconds} = error) do
    {_status, body} = KeyfleetWeb.WorkspaceRefusal.for_error(error)
    KeyfleetWeb.ToolErrors.text(body, seconds)
  end
end
