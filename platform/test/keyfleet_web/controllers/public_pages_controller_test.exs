defmodule KeyfleetWeb.PublicPagesControllerTest do
  use KeyfleetWeb.ConnCase, async: true

  alias KeyfleetWeb.PublicDocuments

  test "PRIVACY: the policy is on /privacy and does not carry draft placeholders" do
    conn = get(build_conn(), "/privacy")
    body = html_response(conn, 200)

    assert body =~ "Keyfleet Privacy Policy"
    assert body =~ "mailto:build@regents.sh"
    refute body =~ "INSERT"
  end

  test "TERMS: the terms are on /terms and do not carry draft placeholders" do
    conn = get(build_conn(), "/terms")
    body = html_response(conn, 200)

    assert body =~ "Keyfleet Terms of Use"
    assert body =~ "mailto:build@regents.sh"
    refute body =~ "INSERT"
  end

  # Each page names itself in the tab and describes itself for search, from
  # the one list in PublicDocuments; the site name is added once.
  test "every reading page has its own title and description" do
    pages =
      for path <- ~w(/docs /about /contact /opportunities /privacy /terms) do
        document = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
        title = document |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim()

        [description] =
          document |> LazyHTML.query("meta[name=description]") |> LazyHTML.attribute("content")

        assert String.ends_with?(title, " · Keyfleet"), "#{path} is titled #{title}"
        {title, description}
      end

    assert pages |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 6
    assert pages |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 6

    assert {"Terms of Use · Keyfleet", "The terms that apply when you use Keyfleet."} in pages
  end

  test "the homepage is titled with the site name alone" do
    document = build_conn() |> get("/") |> html_response(200) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() == "Keyfleet"
  end

  test "a page inside the app is titled by its route" do
    document =
      build_conn()
      |> get("/app/fleets/fibonacci_syndicate")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() ==
             "Fleet · Keyfleet"
  end

  test "reading and home first renders honor the saved theme" do
    for theme <- ["light", "dark"], path <- ["/privacy", "/"] do
      document =
        build_conn()
        |> put_req_cookie("regent_theme", theme)
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()

      expected = if path == "/", do: "dark", else: theme

      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("data-brand") == [
               "platform"
             ]

      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("data-theme") == [expected]

      assert document
             |> LazyHTML.query("meta[name=color-scheme]")
             |> LazyHTML.attribute("content") == [expected]
    end
  end

  test "before any choice a reading page carries no theme and follows the device" do
    document =
      build_conn()
      |> get("/privacy")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("html[data-theme]") |> Enum.count() == 0

    assert document
           |> LazyHTML.query("meta[name=color-scheme]")
           |> LazyHTML.attribute("content") == ["dark light"]

    assert document
           |> LazyHTML.query("meta[name=theme-color]")
           |> LazyHTML.attribute("media") == [
             "(prefers-color-scheme: light)",
             "(prefers-color-scheme: dark)"
           ]

    home =
      build_conn()
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert home |> LazyHTML.query("html") |> LazyHTML.attribute("data-theme") == ["dark"]
  end

  test "the tool manifest lists the three read tools and the docs list them too" do
    manifest = build_conn() |> get("/capabilities") |> json_response(200)
    assert Enum.map(manifest["tools"], & &1["name"]) == ["about", "how_it_works", "docs"]

    for path <- ["/docs", "/llms.txt"] do
      body =
        build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

      assert body =~ "| `about` | `GET /about` | Nothing |"
      assert body =~ "| `how_it_works` | `GET /how-it-works` | Nothing |"
      assert body =~ "| `docs` | `GET /docs` | Nothing |"
    end
  end

  test "every answer lets only this site's pages offer browser tools" do
    for {path, accept} <- [{"/", "text/html"}, {"/docs", "text/markdown"}, {"/healthz", "*/*"}] do
      conn = build_conn() |> put_req_header("accept", accept) |> get(path)
      assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
    end
  end

  test "the discovery files carry an ETag of their body and a five-minute public cache" do
    for path <-
          ~w(/openapi.json /robots.txt /llms.txt /capabilities /.well-known/security.txt /.well-known/api-catalog) do
      answer = get(build_conn(), path)
      digest = Base.encode16(:crypto.hash(:sha256, answer.resp_body), case: :lower)

      assert answer.status == 200
      assert get_resp_header(answer, "etag") == [~s("#{digest}")]
      assert get_resp_header(answer, "cache-control") == ["public, max-age=300"]
    end
  end

  test "security.txt names the contact, expires a year out and points at itself" do
    body = build_conn() |> get("/.well-known/security.txt") |> response(200)
    fields = for line <- String.split(body, "\n", trim: true), into: %{}, do: field(line)

    {:ok, expires, 0} = DateTime.from_iso8601(fields["Expires"])

    assert fields["Contact"] == "mailto:build@regents.sh"
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 300..366
    assert fields["Canonical"] == PublicDocuments.url("/.well-known/security.txt")
    assert fields["Policy"] == PublicDocuments.url("/contact")
  end

  test "the API catalog is an RFC 9727 linkset naming the OpenAPI file and the docs" do
    answer = get(build_conn(), "/.well-known/api-catalog")

    assert get_resp_header(answer, "content-type") == [
             ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727")
           ]

    assert %{"linkset" => [link]} = Jason.decode!(answer.resp_body)
    assert link["anchor"] == PublicDocuments.url("/api/v1")
    assert [%{"href" => openapi}] = link["service-desc"]
    assert openapi == PublicDocuments.url("/openapi.json")
    assert [%{"href" => docs}] = link["service-doc"]
    assert docs == PublicDocuments.url("/docs")
  end

  test "every sitemap entry says when it last changed" do
    body = build_conn() |> get("/sitemap.xml") |> response(200)
    entries = Regex.scan(~r{<url><loc>[^<]+</loc><lastmod>([^<]+)</lastmod></url>}, body)

    assert entries != []
    assert length(entries) == length(Regex.scan(~r/<url>/, body))

    assert Enum.all?(entries, fn [_, lastmod] ->
             match?({:ok, _, 0}, DateTime.from_iso8601(lastmod))
           end)
  end

  defp field(line) do
    [name, value] = String.split(line, ": ", parts: 2)
    {name, value}
  end
end
