defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Fleets
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - the four fleets in catalog order, each opening its own map
  # - a card shows its fleet's newest open goal and featured item once connected,
  #   and the first render reads neither
  # - a notice about one fleet refreshes that fleet's card alone, and only
  #   after the pause
  # - the Markdown homepage links each fleet to its own page for what it is
  #   doing, and every fleet's page, and those pages exist
  # - launch-gate: internal links stay on the fleets' maps, the account page,
  #   the public documents, or anchors that exist

  @syndicate "fibonacci_syndicate"
  @cascade "fibonacci_cascade"

  setup do
    Fleets.bootstrap_catalog!()
    Enum.each(Fleets.catalog_ids(), &Workspace.open_log/1)
    :ok
  end

  test "SMOKE: the homepage mounts and keeps its landmark", %{conn: conn} do
    assert conn |> get("/") |> html_response(200)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#public-home")
    refute has_element?(view, "#app-shell")
  end

  test "the four fleets are cards, in catalog order, each opening its map", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    ids = Fleets.catalog_ids()
    assert attribute(html, ".rl-fleet-card", "id") == Enum.map(ids, &"home-fleet-#{&1}")

    for %{id: id, name: name} <- Fleets.catalog() do
      assert has_element?(view, ~s(#home-fleet-#{id} a[href="/app/fleets/#{id}"] h3), name)
    end

    assert attribute(html, ".key-map-preview", "data-layout") ==
             ~w(fibonacci fibonacci classic accelerant)
  end

  test "a card shows its fleet's newest open goal and what it features, once connected",
       %{conn: conn} do
    goal("Sell the first audit", %{"open_questions" => ["Who pays for it?"]})
    Workspace.edit(@syndicate, goal("Ship the site"), %{"status" => "dropped"})

    static = conn |> get("/") |> html_response(200)
    assert attribute(static, "[data-fleet-trying]", "class") == []

    {:ok, view, _html} = live(conn, "/")
    render_async(view)

    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-trying]") ==
             "Trying: Sell the first audit"

    assert text(view, "#home-fleet-#{@cascade} [data-fleet-trying]") == "No goal set yet"

    assert has_element?(
             view,
             ~s(#home-fleet-#{@syndicate} [data-fleet-featured][data-kind="open_question"]),
             "Who pays for it?"
           )

    assert has_element?(
             view,
             ~s(#home-fleet-#{@syndicate} [data-fleet-latest][data-kind="status"]),
             "Ship the site"
           )
  end

  test "a notice about one fleet refreshes that fleet's card alone, after a pause",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view)

    goal("Sell the first audit")
    Workspace.create(@cascade, "goal", %{"title" => "Map the cascade", "outcome" => "O"})

    send(view.pid, {:graph_head, @syndicate, "log_fixture", 2})
    render(view)
    render_async(view)
    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-trying]") == "No goal set yet"

    send(view.pid, {:refresh, @syndicate})
    render(view)
    render_async(view)

    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-trying]") ==
             "Trying: Sell the first audit"

    assert text(view, "#home-fleet-#{@cascade} [data-fleet-trying]") == "No goal set yet"
  end

  test "the Markdown homepage sends agents to each fleet's own page for what it is doing",
       %{conn: conn} do
    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    for %{id: id, name: name} <- Fleets.catalog() do
      [_, section] = String.split(markdown, "\n## #{name}\n", parts: 2)
      [_, path] = Regex.run(~r{\[What it’s doing right now\]\(https?://[^/]+(/[^)]+)\)}, section)
      assert path == "/fleets/#{id}.md"
      assert build_conn() |> get(path) |> response(200) =~ name
    end

    [_, all] = Regex.run(~r{\[all fleets\]\(https?://[^/]+(/[^)]+)\)}, markdown)
    assert build_conn() |> get(all) |> response(200) =~ "Keyfleet Syndicate"
  end

  @open_paths ~w(/account /llms.txt /docs /about /contact /opportunities /privacy /terms)

  test "the public homepage links only to known pages and to anchors that exist",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")
    fleet_paths = Enum.map(Fleets.catalog_ids(), &"/app/fleets/#{&1}")
    briefing = conn |> get("/opportunities") |> html_response(200) |> attribute("[id]", "id")

    for href <- attribute(html, "a", "href"),
        href != "/",
        not String.starts_with?(href, "https://") do
      case String.split(href, "#", parts: 2) do
        ["", anchor] -> assert anchor in anchors
        ["/opportunities", anchor] -> assert anchor in briefing
        [path] -> assert path in @open_paths or path in fleet_paths
      end
    end
  end

  defp goal(title, data \\ %{}),
    do:
      Workspace.create(@syndicate, "goal", Map.merge(%{"title" => title, "outcome" => "O"}, data))

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp attribute(html, selector, name),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
