defmodule KeyfleetWeb.PublicPagesControllerTest do
  use KeyfleetWeb.ConnCase, async: true

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
end
