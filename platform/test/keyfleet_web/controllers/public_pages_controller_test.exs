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

  test "every code block and table on the docs page can take keyboard focus, so a wide one can be scrolled" do
    blocks = build_conn() |> get("/docs") |> html_response(200) |> LazyHTML.from_document()
    blocks = LazyHTML.query(blocks, ".public-document :is(pre, table)")

    refute Enum.empty?(blocks)
    assert blocks |> LazyHTML.filter("[tabindex='0']") |> Enum.count() == Enum.count(blocks)
  end

  test "every link the guides make to a docs section opens at that section" do
    docs = build_conn() |> get("/docs") |> html_response(200) |> LazyHTML.from_document()

    sections =
      for file <- Path.wildcard("priv/public/*.md"),
          [_, id] <- Regex.scan(~r{/docs#([a-z0-9-]+)}, File.read!(file)),
          uniq: true,
          do: id

    refute sections == []

    for id <- sections do
      assert docs |> LazyHTML.query("##{id}") |> Enum.count() == 1, "/docs##{id} opens nowhere"
    end
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

  test "the homepage is titled with the site name and what it is for" do
    document = build_conn() |> get("/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() ==
             "Keyfleet · Persistent teams for personal AI agents"
  end

  test "a page inside the app is titled by its route" do
    document =
      build_conn()
      |> get("/syndicate/1")
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

      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("data-brand") == [
               "platform"
             ]

      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("data-theme") == [theme]

      assert document
             |> LazyHTML.query("meta[name=color-scheme]")
             |> LazyHTML.attribute("content") == [theme]
    end
  end

  test "before any choice a reading page and home are light" do
    for path <- ["/privacy", "/"] do
      document =
        build_conn()
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()

      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("data-theme") == ["light"]

      assert document
             |> LazyHTML.query("meta[name=color-scheme]")
             |> LazyHTML.attribute("content") == ["light"]

      assert document
             |> LazyHTML.query("meta[name=theme-color]")
             |> LazyHTML.attribute("content") == ["#e5e3d2"]
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

  test "a Markdown address that isn't here answers in Markdown and points to the agent guide" do
    guide = "(#{PublicDocuments.url("/llms.txt")})"

    for path <- ["/nope.md", "/docs/nope.md"] do
      answer = get(build_conn(), path)
      assert response_content_type(answer, :md) =~ "text/markdown", path
      assert response(answer, 404) =~ guide, path
    end

    {404, headers, body} =
      assert_error_sent(404, fn -> get(build_conn(), "/agents/nope/skill.md") end)

    assert {"content-type", "text/markdown; charset=utf-8"} in headers
    assert body =~ guide
  end
end
