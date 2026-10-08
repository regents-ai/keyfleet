defmodule KeyfleetWeb.PublicPagesController do
  @moduledoc "Public documentation and discovery; no account or database reads."
  use KeyfleetWeb, :controller
  alias KeyfleetWeb.PublicDocuments

  def show(conn, _params) do
    document = PublicDocuments.document(conn.request_path)
    render(conn, :show, [document: document] ++ PublicDocuments.page(conn.request_path))
  end

  def openapi(conn, _params) do
    body = Jason.encode!(PublicDocuments.openapi())
    conn |> cached(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def llms(conn, _params) do
    body = PublicDocuments.llms()
    conn |> cached(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def capabilities(conn, _params) do
    body = Jason.encode!(Keyfleet.Capabilities.manifest())
    conn |> cached(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def robots(conn, _params) do
    body = "User-agent: *\nAllow: /\n\nSitemap: #{PublicDocuments.url("/sitemap.xml")}\n"
    conn |> cached(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def security(conn, _params) do
    body = PublicDocuments.security_txt()
    conn |> cached(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  # The body is JSON built from this site's own addresses, sent as a linkset with
  # the RFC 9727 profile, which Sobelow does not read as a safe content type.
  # sobelow_skip ["XSS.SendResp"]
  def api_catalog(conn, _params) do
    body = Jason.encode!(PublicDocuments.api_catalog())

    conn
    |> cached(body)
    |> put_resp_content_type(
      ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"),
      nil
    )
    |> send_resp(200, body)
  end

  def sitemap(conn, _params),
    do:
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, PublicDocuments.sitemap())

  # These documents change only with a release: a sha256 ETag of the body and a
  # five-minute public cache, as `KeyfleetWeb.AgentFilesController` sends.
  defp cached(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end

defmodule KeyfleetWeb.PublicPagesHTML do
  @moduledoc false
  use KeyfleetWeb, :html

  def show(assigns) do
    ~H"""
    <div class="rl-root legal-root rg-sheet rg-frame public-document">
      <header class="legal-header">
        <a href={~p"/"} class="legal-home">Keyfleet</a>
        <nav class="legal-nav" aria-label="Pages">
          <a
            :for={
              {label, path} <- [
                {"Opportunities", "/opportunities"},
                {"Docs", "/docs"},
                {"About", "/about"},
                {"Contact", "/contact"},
                {"Privacy", "/privacy"},
                {"Terms", "/terms"}
              ]
            }
            href={path}
            aria-current={if(@conn.request_path == path, do: "page")}
          >
            {label}
          </a>
        </nav>
      </header>
      <main class="legal-page">
        {KeyfleetWeb.PublicDocuments.html(@document.markdown)}
      </main>
    </div>
    """
  end
end
