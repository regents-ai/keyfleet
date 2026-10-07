defmodule KeyfleetWeb.Plugs.LaunchGate do
  @moduledoc """
  While Keyfleet is closed (`KEYFLEET_APP_SURFACES=off`) the site is its
  early-access page and nothing else. This plug runs in the endpoint before
  anything is served, and it is the one place that says what stays reachable:

    * `/early` and its form, the Privacy Policy (`/privacy`) and the Terms of
      Use (`/terms`), as pages or as Markdown;
    * `/healthz`, `/robots.txt`, `/sitemap.xml` (which then lists only those
      three pages), `/.well-known/security.txt` and `/.well-known/hub-jwks.json`,
      the keys the fleets' notebook hubs check this site's passes with;
    * the site's static files: its stylesheets, scripts, fonts, images and
      icons. The HTTP contract closes with the API it describes.

  Every other page a browser opens, `/` included, is sent to `/early` with a
  302. Every other address answers 503 with `Retry-After`: the `not_open_yet`
  JSON refusal for the API, sign-in, key metadata and the other JSON documents,
  and one line of Markdown for the rest, among them the agent guides, the fleet
  directory and the contract. Signing out closes with the rest of sign-in.

  A LiveView already open in a browser moves over its socket, which no plug
  sees; `KeyfleetWeb.Live.LaunchGateHook` sends it to `/early` too.

  With the switch on, every request passes. The setting is read on each
  request, so a deploy opens or closes the site without rebuilding the release.
  """

  import Plug.Conn

  alias KeyfleetWeb.{ContentSecurityPolicy, Refusal}

  @open_pages ~w(/early /privacy /terms)
  @open_files ~w(/healthz /robots.txt /sitemap.xml /.well-known/security.txt /.well-known/hub-jwks.json)
  @static_folders ~w(assets fonts images)
  @contract "api-contract.openapiv3.yaml"
  @static_files KeyfleetWeb.static_paths() -- [@contract | @static_folders]
  # A release also serves each file under a fingerprinted name, `favicon-<digest>.ico`.
  @fingerprinted Enum.map(@static_files, &(Path.rootname(&1) <> "-"))

  # The addresses programs read, answered in JSON when closed.
  @json_addresses [
    ["api"],
    ["auth"],
    ["metadata"],
    ["capabilities"],
    [".well-known", "api-catalog"]
  ]

  @doc "True while the product surfaces are open."
  def app_surfaces_enabled?, do: Application.fetch_env!(:keyfleet, :app_surfaces)

  @doc "The pages a visitor can open while the site is closed."
  def open_pages, do: @open_pages

  def init(opts), do: opts

  def call(conn, _opts) do
    if app_surfaces_enabled?() or open?(conn),
      do: conn,
      else: conn |> closed() |> halt()
  end

  defp open?(%Plug.Conn{request_path: path}) when path in @open_pages or path in @open_files,
    do: true

  defp open?(%Plug.Conn{path_info: [folder | _rest]}) when folder in @static_folders, do: true

  defp open?(%Plug.Conn{path_info: [file]}),
    do: file in @static_files or String.starts_with?(file, @fingerprinted)

  defp open?(_conn), do: false

  defp closed(conn) do
    cond do
      page?(conn) -> to_early(conn)
      json_address?(conn.path_info) -> conn |> unavailable() |> Refusal.json(503, "not_open_yet")
      true -> conn |> unavailable() |> markdown_line()
    end
  end

  # A page is what a browser opens: a GET of an address that names no file and
  # isn't one programs read, asked for as HTML.
  defp page?(%Plug.Conn{method: method, path_info: path} = conn) when method in ["GET", "HEAD"],
    do: not json_address?(path) and not file?(path) and html?(conn)

  defp page?(_conn), do: false

  defp json_address?(path) do
    Enum.any?(@json_addresses, &(Enum.take(path, length(&1)) == &1)) or
      Path.extname(List.last(path, "")) == ".json"
  end

  defp file?(path), do: Path.extname(List.last(path, "")) != ""

  defp html?(conn) do
    formats = [{"html", "text", "html"}, {"md", "text", "markdown"}]
    RegentAgentAccess.negotiate(get_req_header(conn, "accept"), formats) == "html"
  end

  defp to_early(conn) do
    conn
    |> reading_headers()
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.redirect(to: "/early")
  end

  defp markdown_line(conn) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(503, "This part of the site isn't open yet.\n")
  end

  defp unavailable(conn) do
    conn
    |> reading_headers()
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "3600")
    |> put_resp_header("cache-control", "no-store")
  end

  # The closed answers are plain, so they get the strict reading policy.
  defp reading_headers(conn) do
    Phoenix.Controller.put_secure_browser_headers(conn, %{
      "content-security-policy" => ContentSecurityPolicy.reading()
    })
  end
end
