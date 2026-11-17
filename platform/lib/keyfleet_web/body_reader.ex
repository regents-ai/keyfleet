defmodule KeyfleetWeb.BodyReader do
  @moduledoc """
  The endpoint's body reader. A shared agent request (`/api/agents/v1`) is read
  by the shared SIWA plug's reader, which keeps the exact bytes the agent signed
  and refuses more than 4096 of them. A signed request to the MCP address
  (`/mcp`) is read the same way, up to the parsers' own limit, so
  `KeyfleetWeb.Plugs.McpAgent` can check the signature against those bytes.
  Every other body is read as `RegentIdentity.BodyReader` reads it.

  `signed?/1` is how every address that takes both signed and unsigned
  requests tells them apart.
  """

  @agent_body_limit 4096

  def read_body(%Plug.Conn{path_info: ["api", "agents", "v1" | _rest]} = conn, options),
    do: read_signed(conn, options, @agent_body_limit)

  def read_body(%Plug.Conn{path_info: ["mcp"]} = conn, options) do
    if signed?(conn),
      do: read_signed(conn, options, Keyword.fetch!(options, :length)),
      else: RegentIdentity.BodyReader.read_body(conn, options)
  end

  def read_body(conn, options), do: RegentIdentity.BodyReader.read_body(conn, options)

  @doc """
  Whether `conn` is signed: it carries `x-siwa-signature` or
  `x-siwa-signature-input`. Any other signed header alone, a `content-digest`
  included, leaves a request unsigned.
  """
  def signed?(conn) do
    signature = [Siwa.Contract.signature_header(), Siwa.Contract.signature_input_header()]
    Enum.any?(conn.req_headers, fn {name, _value} -> name in signature end)
  end

  @doc """
  Reads a signed request's body with the shared SIWA reader, which keeps the
  exact bytes in `conn.assigns.raw_body`: `{:ok, body, conn}` for a body of at
  most `limit` bytes however it arrives, `{:more, body, conn}` for a longer
  one, or `{:error, reason}`.

  A read asks for one byte past `limit`. A body sent in chunks that fills a
  read exactly comes back unfinished, so a read of `limit` bytes can't tell a
  body of exactly the limit from a longer one.
  """
  def read_signed(conn, options, limit) do
    case Siwa.AgentAuthPlug.read_body(conn, options, limit + 1) do
      {:ok, body, conn} when byte_size(body) > limit -> {:more, body, conn}
      read -> read
    end
  end
end
