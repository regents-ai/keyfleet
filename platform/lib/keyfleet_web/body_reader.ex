defmodule KeyfleetWeb.BodyReader do
  @moduledoc """
  The endpoint's body reader. A shared agent request (`/api/agents/v1`) is read
  by the shared SIWA plug's reader, which keeps the exact bytes the agent signed
  and refuses more than 4096 of them; every other body is read as
  `RegentIdentity.BodyReader` reads it.
  """

  @agent_body_limit 4096

  def read_body(%Plug.Conn{path_info: ["api", "agents", "v1" | _rest]} = conn, options),
    do: Siwa.AgentAuthPlug.read_body(conn, options, @agent_body_limit)

  def read_body(conn, options), do: RegentIdentity.BodyReader.read_body(conn, options)
end
