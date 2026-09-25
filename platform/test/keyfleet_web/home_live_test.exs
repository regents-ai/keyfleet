defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Actors, Agents, ChainHelpers, Fleets, KeeperHelpers, Keys}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.Components.SendAgent

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - the four fleets in catalog order, each opening its own map
  # - a card shows its fleet's newest open goal and featured item once connected,
  #   and the first render reads neither
  # - a card counts sold keys only once its fleet is on sale and read up to now
  # - a notice about one fleet refreshes that fleet's card alone, and only
  #   after the pause
  # - a burst of notices is answered by one refresh of each fleet it names and
  #   one count of the agents across every fleet
  # - the hero counts the agents here, each once however many fleets it runs
  #   keys in, and keys sold across every fleet once every card has read its
  #   fleet, leaves keys out while a fleet's sales are catching up, follows a
  #   change, and marks the count only with agents here
  # - the hero's command box shows the homepage instruction whole and copies
  #   exactly what it shows
  # - the Markdown homepage links each fleet to its own page for what it is
  #   doing, and every fleet's page, and those pages exist
  # - launch-gate: internal links stay on the fleets' maps, the account page,
  #   the public documents, or anchors that exist

  @syndicate "fibonacci_syndicate"
  @cascade "fibonacci_cascade"
  @owner "0x" <> String.duplicate("a", 40)

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
    render_async(view, 3_000)

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
    render_async(view, 3_000)

    goal("Sell the first audit")
    Workspace.create(@cascade, "goal", %{"title" => "Map the cascade", "outcome" => "O"})

    send(view.pid, {:graph_head, @syndicate, "log_fixture", 2})
    render(view)
    render_async(view, 3_000)
    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-trying]") == "No goal set yet"

    send(view.pid, {:refresh, @syndicate})
    render(view)
    render_async(view, 3_000)

    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-trying]") ==
             "Trying: Sell the first audit"

    assert text(view, "#home-fleet-#{@cascade} [data-fleet-trying]") == "No goal set yet"
  end

  test "a card counts sold keys only once its fleet is on sale and read up to now",
       %{conn: conn} do
    classic = "fleet_tech_classic"

    for fleet <- [@syndicate, @cascade],
        do: KeeperHelpers.deploy!(fleet, "0x" <> String.duplicate("7", 40), 8_453)

    ChainHelpers.seed_cursor!(@syndicate)
    ChainHelpers.seed_cursor!(@cascade, head_block: 5_000, next_block: 1_000)
    for token_id <- 1..3, do: issue!(@syndicate, token_id)

    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "#home-fleet-preview-#{@syndicate}", "data-minted") == ["3"]
    assert attribute(html, "#home-fleet-preview-#{classic}", "data-minted") == ["0"]

    render_async(view, 3_000)

    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-who]") ==
             "3 keys sold · 0 agents here"

    assert text(view, "#home-fleet-#{@cascade} [data-fleet-who]") ==
             "Sales figures are catching up · 0 agents here"

    assert text(view, "#home-fleet-#{classic} [data-fleet-who]") ==
             "Not on sale yet · 0 agents here"
  end

  test "the hero counts every fleet's agents and keys once the cards have read them",
       %{conn: conn} do
    for fleet <- [@syndicate, @cascade] do
      KeeperHelpers.deploy!(fleet, "0x" <> String.duplicate("7", 40), 8_453)
      ChainHelpers.seed_cursor!(fleet)
    end

    for token_id <- 1..3, do: issue!(@syndicate, token_id)
    for token_id <- 1..2, do: issue!(@cascade, token_id)
    run!(@syndicate, 2, 1)
    run!(@cascade, 1, 2)

    static = conn |> get("/") |> html_response(200)
    assert attribute(static, "#home-tally", "id") == ["home-tally"]
    assert attribute(static, "#home-tally p", "class") == []

    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)
    assert text(view, "#home-tally") == "2 agents here · 5 keys sold"

    issue!(@cascade, 3)
    send(view.pid, {:refresh, @cascade})
    render(view)
    render_async(view, 3_000)
    assert text(view, "#home-tally") == "2 agents here · 6 keys sold"
  end

  test "the hero counts an agent running keys in two fleets once", %{conn: conn} do
    for fleet <- [@syndicate, @cascade] do
      KeeperHelpers.deploy!(fleet, "0x" <> String.duplicate("7", 40), 8_453)
      ChainHelpers.seed_cursor!(fleet)
      issue!(fleet, 1)
      run!(fleet, 1, 1)
    end

    issue!(@cascade, 2)
    run!(@cascade, 2, 2)

    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)

    assert text(view, "#home-fleet-#{@syndicate} [data-fleet-who]") ==
             "1 key sold · 1 agent here"

    assert text(view, "#home-fleet-#{@cascade} [data-fleet-who]") ==
             "2 keys sold · 2 agents here"

    assert text(view, "#home-tally") == "2 agents here · 3 keys sold"
  end

  test "the hero leaves keys out of its count while a fleet's sales are catching up",
       %{conn: conn} do
    KeeperHelpers.deploy!(@syndicate, "0x" <> String.duplicate("7", 40), 8_453)
    ChainHelpers.seed_cursor!(@syndicate, head_block: 5_000, next_block: 1_000)
    for token_id <- 1..3, do: issue!(@syndicate, token_id)

    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)

    assert text(view, "#home-tally") == "0 agents here"
  end

  test "the hero's count is marked only while agents are here", %{conn: conn} do
    KeeperHelpers.deploy!(@syndicate, "0x" <> String.duplicate("7", 40), 8_453)
    ChainHelpers.seed_cursor!(@syndicate)
    issue!(@syndicate, 1)

    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)
    assert text(view, "#home-tally") == "0 agents here · 1 key sold"
    refute has_element?(view, "#home-tally [data-tally-dot]")

    run!(@syndicate, 1, 1)
    send(view.pid, {:refresh, @syndicate})
    send(view.pid, {:refresh, :agents})
    render(view)
    render_async(view, 3_000)
    assert text(view, "#home-tally") == "1 agent here · 1 key sold"
    assert has_element?(view, "#home-tally [data-tally-dot]")
  end

  test "the command box shows the homepage instruction and copies what it shows",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "#home-instruction-copy", "data-copy-text") ==
             [SendAgent.home_instruction()]

    assert text(view, "#home-instruction") == SendAgent.home_instruction()
  end

  test "a burst of notices is answered by one refresh of each fleet and one count of agents",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)

    # Watch the pauses the page sets before reading a fleet again.
    :erlang.trace_pattern({:erlang, :send_after, 3}, true, [:global])
    :erlang.trace(view.pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({:erlang, :send_after, 3}, false, [:global]) end)

    send(view.pid, {:graph_head, @syndicate, "log_fixture", 2})
    send(view.pid, {:graph_head, @syndicate, "log_fixture", 3})
    send(view.pid, {:proposals_changed, @syndicate})
    send(view.pid, {:rooms_changed, @cascade})
    render(view)

    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @syndicate}]}}
    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, :agents}]}}
    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @cascade}]}}
    refute_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, _}]}}, 100

    # Once the fleet has read again, its next notice sets a pause of its own;
    # the agents are still due their read.
    send(view.pid, {:refresh, @syndicate})
    send(view.pid, {:graph_head, @syndicate, "log_fixture", 4})
    render(view)

    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @syndicate}]}}
    refute_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, _}]}}, 100
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

    [_, all] = Regex.run(~r{\[Every fleet\]\(https?://[^/]+(/[^)]+)\)}, markdown)
    assert build_conn() |> get(all) |> response(200) =~ "Keyfleet Syndicate"
  end

  @open_paths ~w(/account /llms.txt /skill.md /docs /about /contact /opportunities /privacy /terms)

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

  defp issue!(fleet_id, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # An agent of its own, numbered `agent`, running `fleet_id`'s key `token_id`.
  defp run!(fleet_id, token_id, agent) do
    operator = %Actors.Agent{
      wallet_address: "0x" <> String.pad_leading(Integer.to_string(agent), 40, "c"),
      chain_id: 8_453,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(%{name: "Runner #{agent}", declared_harness: "test"}, actor: operator)
    request = Keys.request_pairing!(fleet_id, token_id, %{}, actor: operator)
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
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
