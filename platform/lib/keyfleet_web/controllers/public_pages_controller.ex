defmodule KeyfleetWeb.PublicPagesController do
  @moduledoc "Public documentation and discovery; no account or database reads."
  use KeyfleetWeb, :controller
  alias KeyfleetWeb.PublicDocuments

  def show(conn, _params) do
    case PublicDocuments.document(conn.request_path) do
      nil ->
        raise KeyfleetWeb.NotFoundError

      document ->
        render(conn, :show, [document: document] ++ PublicDocuments.page(conn.request_path))
    end
  end

  @doc "`/app` opens the Regents Club's hall, the fleet every Club Pass comes with."
  def app(conn, _params), do: redirect(conn, to: ~p"/app/fleets/regents_club")

  @doc "`/agent` and `/start`, where a new agent often looks first, open the Agents page."
  def agents_start(conn, _params), do: redirect(conn, to: ~p"/agents")

  def openapi(conn, _params) do
    body = Jason.encode!(PublicDocuments.openapi())
    conn |> cached(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def llms(conn, _params) do
    body = PublicDocuments.llms()
    conn |> cached(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def agents(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, PublicDocuments.agents())
  end

  def help(conn, _params) do
    body = PublicDocuments.help()
    conn |> cached(body) |> put_resp_content_type("text/markdown") |> send_resp(200, body)
  end

  def capabilities(conn, _params) do
    body =
      Keyfleet.Capabilities.manifest()
      |> Map.put("build", Application.fetch_env!(:keyfleet, :build))
      |> Map.put("versions", Keyfleet.Capabilities.versions())
      |> Jason.encode!()

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

  # The body is XML listing this site's own page addresses, each one escaped.
  # sobelow_skip ["XSS.SendResp"]
  def sitemap(conn, _params),
    do:
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, PublicDocuments.sitemap())

  @doc "A public page as JSON, `{title, markdown}`: the `about` and `docs` tools."
  def document(conn, _params) do
    %{document: path, page: page} = conn.assigns
    %{markdown: markdown} = PublicDocuments.document(path)
    json(conn, %{title: PublicDocuments.page(page)[:page_title], markdown: markdown})
  end

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
                {"Agents", "/agents"},
                {"Changelog", "/changelog"},
                {"About", "/about"},
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
