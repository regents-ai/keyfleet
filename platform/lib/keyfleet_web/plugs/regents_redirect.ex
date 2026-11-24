defmodule KeyfleetWeb.Plugs.RegentsRedirect do
  @moduledoc """
  Redirects `keyfleet.ai` and `www.keyfleet.ai` traffic to `https://regents.sh`
  once `:redirect_to_regents` is enabled, while keeping `/healthz` and
  `/.well-known/hub-jwks.json` served locally for Fly health checks and the
  notebook/code hubs.

  Runs immediately after `NotebookGateway` and `CodeGateway`, so
  `*.notebooks.keyfleet.ai` and `code.keyfleet.ai` are already handled before
  this plug runs.
  """
  @behaviour Plug

  import Plug.Conn

  @regents_origin "https://regents.sh"
  @passthrough_paths ["/healthz", "/.well-known/hub-jwks.json"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Application.get_env(:keyfleet, :redirect_to_regents, false) and not passthrough?(conn) do
      redirect_to_regents(conn)
    else
      conn
    end
  end

  defp passthrough?(%Plug.Conn{method: method, request_path: path})
       when method in ["GET", "HEAD"] and path in @passthrough_paths,
       do: true

  defp passthrough?(_conn), do: false

  defp redirect_to_regents(conn) do
    target = @regents_origin <> map_path(normalize_path(conn.request_path)) <> query_suffix(conn)
    status = if conn.method in ["GET", "HEAD"], do: 301, else: 308

    conn
    |> put_resp_header("location", target)
    |> send_resp(status, "")
    |> halt()
  end

  defp normalize_path("/"), do: "/"

  defp normalize_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp map_path("/"), do: "/keyfleet"
  defp map_path("/account"), do: "/account"
  defp map_path("/account/" <> _rest = path), do: path
  defp map_path("/pair"), do: "/pair"
  defp map_path("/points"), do: "/account/points"
  defp map_path("/points/" <> _rest), do: "/account/points"
  defp map_path("/api/agents/v1"), do: "/api/agents/v1"
  defp map_path("/api/agents/v1/" <> _rest = path), do: path
  defp map_path("/api/v1/health"), do: "/api/v1/health"
  defp map_path("/api/v1/account"), do: "/api/v1/account"
  defp map_path("/api/v1/account/" <> _rest = path), do: path
  defp map_path("/api/v1/profile"), do: "/api/v1/profile"
  defp map_path("/api/v1/profile/" <> _rest = path), do: path
  defp map_path("/api/v1/messages/" <> _rest = path), do: path
  defp map_path("/api/v1"), do: "/api/v1/keyfleet"
  defp map_path("/api/v1/" <> rest), do: "/api/v1/keyfleet/" <> rest
  defp map_path(path), do: "/keyfleet" <> path

  defp query_suffix(%Plug.Conn{query_string: ""}), do: ""
  defp query_suffix(%Plug.Conn{query_string: query}), do: "?" <> query
end
