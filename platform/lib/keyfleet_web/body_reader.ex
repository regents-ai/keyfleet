defmodule KeyfleetWeb.BodyReader do
  @moduledoc """
  How a body an agent may have signed is read. `read_body/2` is the body
  reader of the shared agent address (`/api/agents/v1`, the router's
  `:agent_pairing`): the shared SIWA plug's reader, which keeps the exact bytes
  the agent signed, up to its parser's `:length`.

  `signed?/1` is how every address that takes both signed and unsigned
  requests tells them apart.
  """

  def read_body(conn, options), do: read_signed(conn, options, Keyword.fetch!(options, :length))

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
  Reads a body with the shared SIWA reader, which keeps the exact bytes in
  `conn.assigns.raw_body`, for a signature to be checked against them or for
  a call to be decoded only once its caller is known
  (`KeyfleetWeb.Plugs.McpAgent`): `{:ok, body, conn}` for a body of at
  most `limit` bytes however it arrives, `{:more, partial, conn}` for a longer
  one, or `{:error, reason}`.

  A read asks for one byte past `limit`. A body sent in chunks that fills a
  read exactly comes back unfinished, so a read of `limit` bytes can't tell a
  body of exactly the limit from a longer one. Over HTTP/2 one frame can carry
  more than a read asks for, which the shared reader refuses by raising: that
  body is longer too, and `partial` is empty.
  """
  def read_signed(conn, options, limit) do
    case Siwa.AgentAuthPlug.read_body(conn, options, limit + 1) do
      {:ok, body, conn} when byte_size(body) > limit -> {:more, body, conn}
      read -> read
    end
  rescue
    Plug.Parsers.RequestTooLargeError -> {:more, "", conn}
  end
end
