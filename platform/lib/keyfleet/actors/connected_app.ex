defmodule Keyfleet.Actors.ConnectedApp do
  @moduledoc """
  An app a person connected to their Keyfleet account, such as Claude, calling
  the MCP address at `/mcp` with the token its connection holds. `principal` is
  what `RegentOAuth.verify/3` answered for that token: the person's subject,
  the token, the client and the scopes the person approved. It runs only the
  connection's identity tools (`Keyfleet.Agents.Connection`); with the agent
  permission it is listed its paired agent's tools as well, each answering
  `agent_not_paired` (`Keyfleet.Agents.Connection.Listing`). Once that
  identity is paired with the person's account and the person allowed
  Keyfleet's agent permission (`Keyfleet.OAuth.agent_scope/0`), the app calls
  as its paired agent instead (`Keyfleet.Actors.Agent`, `connection`).
  """
  @enforce_keys [:principal]
  defstruct [:principal, role: :connected_app]
end
