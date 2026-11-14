defmodule KeyfleetWeb.ToolErrors do
  @moduledoc """
  What a tool at the Claude connector's address (`/mcp`) says when its action
  refuses: the JSON the same refusal answers over HTTP,
  `{"error": {"code", "message", "hint"}}`, as the tool error's text
  (`AshAi.ToToolError`), with `retry_after` in seconds where HTTP sends
  `Retry-After`. A refusal of a tool that answers as its signed request
  (`KeyfleetWeb.AgentTools.Refused`) is that request's body. A workspace
  refusal takes the workspace's words
  (`KeyfleetWeb.WorkspaceRefusal`), with its `details`. A connected app's
  identity refusal takes this site's own code and words, or, when no answer
  came, the words every Regent site gives it.

  A connected app whose identity isn't its person's paired agent yet is
  listed that agent's tools (`Keyfleet.Agents.Connection.Listing`), and any
  but its identity tools is refused before anything is read, as
  `agent_not_paired` with the steps that pair it (`check_input/3`).

  Input a tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the router's `tool_argument_transformer`), as the action
  itself would refuse it, with the actor and context it would run with: a
  pairing's as `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), another identity tool's in the
  words every Regent site gives it, a fleet tool's with the refusal its signed
  request answers (an unknown fleet as `fleet_unknown`), or else as
  `invalid_request`. A workspace write that names a coming-soon fleet is
  refused once its input has the shape its signed request needs, as every
  agent request about one is (`KeyfleetWeb.Plugs.FleetComingSoon`). A tool
  that answers as its signed request also checks its body as that
  request's is when it runs (`KeyfleetWeb.AgentTools.Run`).
  Input that is not an object, or names an input the action has not, is
  refused too. The check says so in the action's context
  (`input_check`), so it spends no write allowance
  (`Keyfleet.Graph.Validations.WriteAllowance`); the run that follows does.
  """

  alias Keyfleet.Actors.ConnectedApp
  alias Keyfleet.Agents.Connection
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Errors.ComingSoonFleetError
  alias KeyfleetWeb.{Refusal, WorkspaceRefusal}

  @pair_first "Ask your person for a one-use code from Pair New Agent on their Agents page, " <>
                "call pair_identity with it, then call this tool again."

  @doc """
  Casts a tool's `input` as its action takes it. Input it takes goes on to
  AshAi unchanged; other input is refused as `{:error, text}`, and so is any
  tool but an identity tool that a connected app calls before it pairs.
  """
  @spec check_input(AshAi.Tool.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def check_input(%AshAi.Tool{resource: resource}, _arguments, %{actor: %ConnectedApp{}})
      when resource != Connection,
      do: {:error, text(Refusal.body("agent_not_paired", @pair_first))}

  def check_input(%AshAi.Tool{resource: resource, action: %{name: action}}, arguments, context) do
    with %{} <- arguments, %{} = input <- arguments["input"] || %{} do
      resource
      |> Ash.ActionInput.for_action(action, input,
        actor: context[:actor],
        context: Map.put(context[:context] || %{}, :input_check, true)
      )
      |> checked(arguments)
    else
      _not_an_object -> {:error, refused(resource, action, [])}
    end
  end

  defp checked(%Ash.ActionInput{resource: resource, action: %{name: action}} = input, arguments) do
    errors = if shaped?(input), do: opened(input) ++ input.errors, else: input.errors
    if errors == [], do: {:ok, arguments}, else: {:error, refused(resource, action, errors)}
  end

  # The input has the shape a signed request needs: every refusal it has is
  # the workspace's own.
  defp shaped?(%Ash.ActionInput{errors: errors}),
    do: Enum.all?(errors, &WorkspaceRefusal.for_error/1)

  defp opened(%Ash.ActionInput{resource: resource} = input) do
    fleet_id = Ash.ActionInput.get_argument(input, :fleet_id)

    if Ash.Resource.Info.domain(resource) == Keyfleet.Graph and fleet_id in Fleets.catalog_ids() and
         Fleets.coming_soon?(fleet_id, Fleets.get_fleet!(fleet_id)),
       do: [ComingSoonFleetError.exception(fleet_id: fleet_id)],
       else: []
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
    Keyfleet.Graph.Errors.ComingSoonFleetError,
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

defimpl AshAi.ToToolError, for: KeyfleetWeb.AgentTools.Refused do
  def to_tool_error(%{body: body, retry_after: retry_after}),
    do: KeyfleetWeb.ToolErrors.text(body, retry_after)
end
