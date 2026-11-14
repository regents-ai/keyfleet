defmodule Keyfleet.Agents.Connection.Listing do
  @moduledoc """
  Holds only while the connector lists its tools (AshAi's
  `ash_ai_pre_check?`), for an app its person connected with Keyfleet's agent
  permission (`Keyfleet.OAuth.agent_scope/0`) whose identity is not their
  paired agent yet (`Keyfleet.Actors.ConnectedApp`). It is listed every tool
  that agent runs, so the list an app keeps from its first request is still
  right once it pairs. Running one takes the paired agent: until then the call
  is refused as `agent_not_paired` (`KeyfleetWeb.ToolErrors.check_input/3`),
  and the policy beside this check refuses it as well.
  """

  use Ash.Policy.SimpleCheck

  alias Keyfleet.Actors.ConnectedApp

  @impl true
  def describe(_opts),
    do: "the connector is listing tools for an app its person allowed to work as an agent"

  @impl true
  def match?(
        %ConnectedApp{principal: %{scopes: scopes}},
        %{subject: %Ash.ActionInput{context: %{private: %{ash_ai_pre_check?: true}}}},
        _opts
      ),
      do: Keyfleet.OAuth.agent_scope() in scopes

  def match?(_actor, _context, _opts), do: false
end
