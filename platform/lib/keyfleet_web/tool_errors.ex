defmodule KeyfleetWeb.ToolErrors do
  @moduledoc """
  What a tool at the Claude connector's address (`/mcp`) says when its action
  refuses: the JSON the same refusal answers over HTTP,
  `{"error": {"code", "message", "hint"}}`, as the tool error's text
  (`AshAi.ToToolError`), with `retry_after` in seconds where HTTP sends
  `Retry-After`. A connected app's identity refusal takes this site's own code
  and words, or, when no answer came, the words every Regent site gives it.

  Input an identity tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the router's `tool_argument_transformer`): a pairing's as
  `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), and another identity tool's in
  the words every Regent site gives it. The fleet tools' input goes to their
  actions as it came, which refuse it as they do over HTTP.
  """

  alias Keyfleet.Agents.Connection

  @doc """
  Casts an identity tool's `input` as its action takes it. Input it takes, and
  any fleet tool's, goes on to AshAi unchanged; other input is refused as
  `{:error, text}`.
  """
  @spec check_input(AshAi.Tool.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def check_input(%AshAi.Tool{resource: Connection, action: %{name: action}}, arguments, _context) do
    with %{} <- arguments,
         %{} = input <- arguments["input"] || %{},
         %{valid?: true} <- Ash.ActionInput.for_action(Connection, action, input) do
      {:ok, arguments}
    else
      _refused -> {:error, refused(action)}
    end
  end

  def check_input(_fleet_tool, arguments, _context), do: {:ok, arguments}

  defp refused(:pair_identity),
    do: Jason.encode!(%{error: RegentMCPAgents.pairing_input_refusal()})

  defp refused(_identity), do: Jason.encode!(RegentMCPAgents.Tools.refusal())

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
