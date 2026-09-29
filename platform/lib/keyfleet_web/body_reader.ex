defmodule KeyfleetWeb.BodyReader do
  @moduledoc """
  The endpoint's body reader. A shared agent request (`/api/agents/v1`) keeps
  its exact bytes in `conn.assigns.raw_body`, because the agent signed them;
  every other body is read as `RegentIdentity.BodyReader` reads it.
  """

  def read_body(%Plug.Conn{path_info: ["api", "agents", "v1" | _rest]} = conn, options) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, options) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    end
  end

  def read_body(conn, options), do: RegentIdentity.BodyReader.read_body(conn, options)
end
