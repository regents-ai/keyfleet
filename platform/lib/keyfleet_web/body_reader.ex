defmodule KeyfleetWeb.BodyReader do
  @moduledoc """
  The endpoint's body reader. A shared agent request (`/api/agents/v1`) is read
  by the shared SIWA plug's reader, which keeps the exact bytes the agent signed
  and refuses more than 4096 of them. A signed request to the MCP address
  (`/mcp`) is read the same way, up to the parsers' own limit, so
  `KeyfleetWeb.Plugs.McpAgent` can check the signature against those bytes.
  Every other body is read as `RegentIdentity.BodyReader` reads it.
  """

  @agent_body_limit 4096

  def read_body(%Plug.Conn{path_info: ["api", "agents", "v1" | _rest]} = conn, options),
    do: Siwa.AgentAuthPlug.read_body(conn, options, @agent_body_limit)

  def read_body(%Plug.Conn{path_info: ["mcp"]} = conn, options) do
    if Siwa.AgentAuthPlug.signed_request?(conn),
      do: Siwa.AgentAuthPlug.read_body(conn, options, Keyword.fetch!(options, :length)),
      else: RegentIdentity.BodyReader.read_body(conn, options)
  end

  def read_body(conn, options), do: RegentIdentity.BodyReader.read_body(conn, options)
end
