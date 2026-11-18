defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, Repo, Rooms, SharedReading}
  alias Keyfleet.Projects.Publication
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.FleetNow
  alias Phoenix.Socket.Broadcast

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - every way to buy is called "Buy Key", the Key's number and price beside
  #   it and never in its label
  # - while Classic is coming soon, the card's tag names Key 1 and its price,
  #   but "Buy Key" says it can't be pressed, with "Sales open soon" under it,
  #   links nowhere, and the header offers no "Buy Key"
  # - once Classic is on sale, the hero's "Buy Key" and the header's open the
  #   "Buy Key" window, which holds the fleet's own Approve and Buy, and the
  #   line under the button and the card's tag name the Key on offer and its
  #   price after the Keys sold
  # - once every Classic Key is sold, the button can't be pressed and says so
  # - a Classic read that fails is said to have failed and never shown as zero
  # - a burst of notices is answered by one read of each fleet it names, for
  #   every open homepage at once, and a post taken off a wall reads its fleet
  #   again
  # - the page is the hero, then Overview: the headline and what a fleet gives
  #   an agent; the Markdown homepage is the block every agent entry opens
  #   with, then Classic Keyfleet, which says Classic opens soon until it does,
  #   then links its page
  # - "Explore" opens Classic #1's own page; Classic #1's figures each keep
  #   their own name: Keys sold out of all, the agents here, the next Key's
  #   price and the goal it is working on, which links its workspace
  # - under the hero, the four steps in order, Explore, Key, Agent and Work,
  #   each a title with one line
  # - below the hero, Recent: what Classic's Keys made public, newest first,
  #   each its kind, its title as plain text cut to 64 characters and its
  #   Key, a plain link to its place in the Public place; from four they
  #   slide, held twice, the copy hidden and skipped by Tab; and Notebook: the
  #   newest notebook page made public, opening the page. With nothing made
  #   public neither is drawn, and neither costs the page a read
  # - launch-gate: internal links stay on the fleets' maps, workspaces,
  #   proposals and treasuries, the account and pairing pages, the public
  #   documents, or anchors that exist
  # - signed in, the header's name opens the account menu, with Sign out,
  #   Manage Account, the account's agents and Pair New Agent opening the
  #   pairing window, and an agent paired while the page is open shows in it;
  #   Fleets beside the name opens Classic; signed out there is neither

  @classic "fleet_tech_classic"
  @club "regents_club"
  @owner "0x" <> String.duplicate("a", 40)

  setup context do
    Fleets.bootstrap_catalog!()

    unless context[:classic_undeployed] do
      ChainHelpers.deploy!(@classic)
      ChainHelpers.seed_cursor!(@classic)
    end

    Enum.each(Fleets.catalog_ids(), &Workspace.open_log/1)
    read_fleets()
    :ok
  end

  test "SMOKE: the homepage mounts and keeps its landmark", %{conn: conn} do
    assert conn |> get("/") |> html_response(200)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#public-home")
    refute has_element?(view, "#app-shell")
  end

  test "signed in, the homepage has the account menu and Fleets; signed out, neither",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#account-menu")
    refute has_element?(view, "[popovertarget=account-menu]")
    refute has_element?(view, "#shell-fleets")

    wallet = "0x" <> String.duplicate("b", 40)

    account =
      Keyfleet.Accounts.register_verified("did:privy:home-panel", wallet, [wallet],
        actor: %Actors.System{}
      )
      |> then(fn {:ok, account} -> account end)

    {:ok, view, _html} = conn |> init_test_session(%{human_account_id: account.id}) |> live("/")

    assert has_element?(view, "#shell-header #account-chip[popovertarget=account-menu]")
    assert has_element?(view, "#account-control a#shell-fleets[href='/classic/1']", "Fleets")
    refute has_element?(view, "#account-control [data-account-target=sign-out]")
    assert has_element?(view, "#account-menu[popover] [data-account-target=sign-out]", "Sign out")
    assert has_element?(view, ~s(#account-menu a[href="/account"]), "Manage Account")

    assert has_element?(
             view,
             ~s(#account-menu button[data-pair-open][aria-controls="shell-pairing"]),
             "Pair New Agent"
           )

    assert has_element?(view, "dialog#shell-pairing form#shell-pairing-box")

    assert has_element?(view, ~s(#shell-agents a[href="/account/agents"]), "Manage")
    refute has_element?(view, "#shell-agents li")

    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: "did:privy:home-panel"}
      )

    RegentAgents.pair_agent!(code, "Astra", :hermes,
      actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("c", 40)}
    )

    # Announced after the pairing's commit (`RegentAgents.channel/0`), which the
    # test's transaction never makes. The page passes it on to the panel, which
    # draws after the render that follows.
    send(view.pid, :agents_changed)
    render(view)
    assert has_element?(view, "#shell-agents li", "Astra")
  end

  @tag :classic_undeployed
  test "while Classic is coming soon, Buy Key can't be pressed and says why",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(
             view,
             ~s(button#home-buy-key[aria-disabled="true"][aria-describedby="home-buy-why"]),
             "Buy Key"
           )

    assert text(view, "#home-buy-key") == "Buy Key"
    refute has_element?(view, "#home-buy-price")
    assert text(view, "#home-buy-tag") == "Key 1 · 10 USDC"
    assert text(view, "#home-buy-why") == "Sales open soon"
    assert text(view, "#home-classic-price") == "10 USDC"

    assert text(view, "#home-price-tip") =~
             "Keys increase steadily in cost until 100 USDC for the last Key."

    refute has_element?(view, "#shell-get-key")
  end

  test "once Classic is on sale, Buy Key has the Key on offer under it and opens the Buy Key window",
       %{conn: conn} do
    for token_id <- 1..3, do: issue!(@classic, token_id)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    price = Keyfleet.Fleets.Presets.progress(@classic, 3).next_price

    assert text(view, ~s(button#home-buy-key[aria-describedby="home-buy-price"])) == "Buy Key"
    assert text(view, "#home-buy-price") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-tag") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    refute has_element?(view, "#home-buy-why")
    assert text(view, "#home-classic-price") == KeyfleetWeb.FleetLive.usdc(price)
    assert text(view, "#home-classic-sold") == "3 of 1,024"

    view |> element("button#home-buy-key") |> render_click()

    assert has_element?(
             view,
             ~s(dialog#buy-key button#buy-key-button[data-onchain-step="buy"])
           )

    assert has_element?(
             view,
             ~s(dialog#buy-key button#buy-key-approve[data-onchain-step="approve"])
           )

    refute has_element?(view, "#buy-key-go")
  end

  test "once Classic is on sale, the header's Buy Key opens the Buy Key window", %{
    conn: conn
  } do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    assert text(view, "button#shell-get-key") == "Buy Key"
    view |> element("button#shell-get-key") |> render_click()

    assert has_element?(view, "dialog#buy-key")
  end

  test "once Classic is on sale, Buy Key opens its window: the Key cards turning, how many are sold, the Key on offer, the price, Buy and Close",
       %{conn: conn} do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    view |> element("button#home-buy-key") |> render_click()

    assert text(view, "#buy-key-title") == "Buy Key"
    assert has_element?(view, "dialog#buy-key #buy-key-cards.key-cards")

    assert ["Sold", "Key", "Price" <> _tip] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("dialog#buy-key dl dt")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert text(view, "#buy-key-sold") == "1 of 1,024"
    assert text(view, "#buy-key-number") == "2"
    assert text(view, "#buy-key-price") == "10.02 USDC"

    assert text(view, "#buy-key-price-tip") =~
             "Your wallet asks twice: Approve lets the sale take this much USDC, then Buy pays it"

    assert has_element?(view, "dialog#buy-key #buy-key-button")
    assert has_element?(view, "dialog#buy-key #buy-key-close", "Close")
  end

  test "once every Classic Key is sold, Buy Key can't be pressed and says so",
       %{conn: conn} do
    issue!(@classic, 1024)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ~s(button#home-buy-key[aria-disabled="true"]))
    assert text(view, "#home-buy-why") == "1,024/1,024 Keys sold"
    assert text(view, "#home-classic-price") == "Sold out"
  end

  test "a Classic that can't be read leaves the homepage drawn, saying so",
       %{conn: conn} do
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.fleets RENAME TO fleets_away"
    )

    capture_log(fn ->
      first_read(@classic)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#public-home")
      assert text(view, "#home-classic-price") == "—"
      assert text(view, "#home-classic-sold") == "—"
      assert text(view, "#home-buy-why") == "Couldn’t read sales just now"
    end)
  end

  test "a burst of notices is answered by one read of each fleet, for every open homepage",
       %{conn: conn} do
    producer = start_supervised!(FleetNow)
    {:ok, _view, _html} = live(conn, "/")
    {:ok, _view, _html} = live(conn, "/")

    # Watch the fleets the producer reads; the two open pages read nothing.
    :erlang.trace_pattern({FleetNow, :read, 1}, true, [:global])
    :erlang.trace(producer, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({FleetNow, :read, 1}, false, [:global]) end)

    send(producer, {:graph_notable, @club})
    send(producer, {:graph_notable, @club})
    send(producer, {:proposals_changed, @club})
    send(producer, {:keys_changed, @classic, [1]})

    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@club]}}, 2_000
    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@classic]}}
    refute_receive {:trace, ^producer, :call, {FleetNow, :read, _}}, 1_500
  end

  # R-20261019-wall-removal-reads-again: a post taken off a Club wall stopped
  # every open homepage, which knew no such notice. The fleets' reading hears
  # it and reads the fleet again.
  test "a post taken off a wall reads its fleet again" do
    producer = start_supervised!(FleetNow)

    :erlang.trace_pattern({FleetNow, :read, 1}, true, [:global])
    :erlang.trace(producer, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({FleetNow, :read, 1}, false, [:global]) end)

    send(producer, %Broadcast{
      topic: Keyfleet.Rooms.topic(@club, :public),
      event: "wall_removed",
      payload: %{fleet_id: @club, token_id: 17, message_id: Ecto.UUID.generate()}
    })

    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@club]}}, 2_000
  end

  test "the page is the hero then Overview, leading with the headline, and the Markdown homepage is the agents' block then Classic Keyfleet",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert attribute(html, "main section[id]", "id") == ["home-hero", "home-overview"]
    assert text(view, "#home-title") == "A persistent team for your AI agent."

    assert text(view, "#home-lead") ==
             "Agents in a fleet share goals, code and results, and review each other's work."

    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    assert ["# Keyfleet\n\n", after_block] =
             String.split(markdown, KeyfleetWeb.PublicDocuments.opening(), parts: 2)

    assert Regex.scan(~r/^## (.+)$/m, after_block, capture: :all_but_first) == [
             ["Classic Keyfleet"],
             ["More"]
           ]

    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [_, path] = Regex.run(~r{\[Live activity\]\(https?://[^/]+(/[^)]+)\)}, section)
    assert path == "/fleets/fleet_tech_classic.md"
    assert build_conn() |> get(path) |> response(200) =~ "Classic #1"
  end

  test "under the hero, the four steps in order, each a title with one line, none a link",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    steps =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#home-hero ol#home-steps > li")
      |> Enum.map(fn step ->
        step
        |> LazyHTML.query("p")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      end)

    assert ["Explore", "Key", "Agent", "Work"] = Enum.map(steps, &hd/1)
    assert Enum.all?(steps, &match?([_title, line] when line != "", &1))
    assert attribute(html, "#home-steps a", "href") == []
  end

  test "Recent: what Classic's Keys made public, newest first, as plain text, each opening its place in the Public place",
       %{conn: conn} do
    task_item =
      Workspace.create(@classic, "task", %{"title" => "Fix <b>the</b> price reader"}, by: 5)

    long = String.duplicate("Keys bought early are held longer ", 3)
    finding_item = Workspace.create(@classic, "finding", %{"title" => long}, by: 6)
    archived = Workspace.create(@classic, "note", %{"title" => "Withdrawn"}, by: 6)
    Workspace.archive(@classic, archived)

    task = make_public!(%{key: 5, kind: :item, item: task_item})
    finding = make_public!(%{key: 6, kind: :item, item: finding_item})
    make_public!(%{key: 6, kind: :item, item: archived})
    span = post!(8, "**Read** the [sales](https://example.com) from the chain")
    posts = make_public!(Map.merge(%{key: 8, kind: :posts, room: "general"}, span))
    page = make_public!(%{project: "understanding", key: 7, kind: :page, page: page_path(1)})
    made = [page, posts, finding, task]
    read_fleets()
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "main section[id]", "id") ==
             ["home-hero", "home-recent", "home-notebook", "home-overview"]

    shown =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#home-recent-list > li > a")
      |> Enum.map(fn link ->
        Enum.map(
          ~w(kind title key),
          &(link |> LazyHTML.query(".rl-ticker__#{&1}") |> LazyHTML.text())
        )
      end)

    clipped = "Keys bought early are held longer Keys bought early are held…"

    assert shown == [
             ["Notebook page", "Keyfleet Classic #1 Collaborative Understanding", "Key 7"],
             ["Posts", "Read the sales from the chain", "Key 8"],
             ["Finding", clipped, "Key 6"],
             ["Task", "Fix <b>the</b> price reader", "Key 5"]
           ]

    assert String.length(clipped) <= 64
    assert html =~ "Fix &lt;b&gt;the&lt;/b&gt; price reader"

    assert attribute(html, "#home-recent-list a", "href") ==
             Enum.map(made, &"/classic/1/workspace?place=public#public-#{&1.id}")

    refute has_element?(view, "#home-recent a[data-phx-link]")

    # Four or more slide, held twice; the copy is hidden from screen readers
    # and skipped by Tab, and holds no ids.
    assert attribute(html, "#home-recent-band", "data-slides") == [""]
    copy = "#home-recent-band ul[aria-hidden=\"true\"][inert]"
    assert length(attribute(html, "#{copy} > li > a", "href")) == 4
    assert attribute(html, "#{copy} [id]", "id") == []

    # Each link lands on its own place in the Public place, as anyone reads it.
    {:ok, public, _html} = live(build_conn(), "/classic/1/workspace?place=public")
    for publication <- made, do: assert(has_element?(public, "#public-#{publication.id}"))
  end

  test "Notebook: the newest notebook page made public, by its project's title and its Key, opening the page; fewer than four stand still",
       %{conn: conn} do
    make_public!(%{key: 3, kind: :page, page: page_path(1)})
    make_public!(%{project: "understanding", key: 7, kind: :page, page: page_path(2)})
    read_fleets()

    {:ok, view, html} = live(conn, "/")

    assert text(view, "#home-notebook-title") == "Notebook"
    assert text(view, "#home-notebook-name") == "Keyfleet Classic #1 Collaborative Understanding"
    assert text(view, "#home-notebook .rl-notebook__key") == "Key 7"

    assert attribute(html, "a#home-notebook-open", "href") == [
             Keyfleet.Notebooks.url(@classic, page_path(2))
           ]

    assert attribute(html, "a#home-notebook-open", "target") == ["_blank"]
    assert attribute(html, "a#home-notebook-open", "rel") == ["noopener noreferrer"]

    assert attribute(html, "#home-recent-list > li", "id") |> length() == 2
    assert attribute(html, "#home-recent-band", "data-slides") == []
    assert attribute(html, "#home-recent-band ul", "id") == ["home-recent-list"]
  end

  test "with nothing made public there is neither Recent nor Notebook, and no row for them",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert attribute(html, "main section[id]", "id") == ["home-hero", "home-overview"]
    assert attribute(html, "main .rl-recent", "class") == []
  end

  test "what Classic's Keys made public costs the homepage no read of its own", %{conn: conn} do
    get(conn, "/")
    {before, _conn} = Keyfleet.QueryHelpers.queries_during(fn -> get(build_conn(), "/") end)

    for n <- 1..8, do: make_public!(%{key: n, kind: :page, page: page_path(n)})
    read_fleets()

    {count, served} = Keyfleet.QueryHelpers.queries_during(fn -> get(build_conn(), "/") end)
    assert html_response(served, 200) =~ ~s(id="home-recent")
    assert count == before
  end

  test "Explore opens Classic #1's page, over Classic #1's figures", %{conn: conn} do
    for token_id <- 1..2, do: issue!(@classic, token_id)
    Workspace.create(@classic, "goal", %{"title" => "Chart the bay", "outcome" => "O"}, by: 1)
    read_fleets()
    Keyfleet.Agents.Here.read(@classic)

    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "a#home-explore", "href") == ["/classic/1"]
    # Every fleet page draws in another live session, so no link here asks for
    # a live move: it would be refused and loaded whole anyway.
    refute has_element?(view, "main a[data-phx-link]")
    assert text(view, "#home-explore") == "Explore"
    # A press is counted under the step's kept name (assets/js/launch_steps.ts).
    assert attribute(html, "a#home-explore", "data-step") == ["watch"]

    assert text(view, "#home-hero-fleet") == "Classic #1 now"

    assert ["Keys sold", "Agents here", "Next Key" <> _tip] =
             html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#home-classic-facts dt")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert text(view, "#home-classic-sold") == "2 of 1,024"
    assert text(view, "#home-classic-agents") == "0"
    assert text(view, "#home-classic-goal") == "Working on Chart the bay"
    assert attribute(html, "#home-classic-goal a", "href") == ["/classic/1/workspace"]
  end

  test "agents not yet counted show a dash, never none", %{conn: conn} do
    SharedReading.delete(Keyfleet.Agents.Here.fleet_key(@classic))
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "#home-classic-agents") == "—"
    refute has_element?(view, "#home-classic-goal")
  end

  @tag :classic_undeployed
  test "the Markdown homepage says Classic opens soon until it does", %{conn: conn} do
    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "Sales open soon."
    refute section =~ "Live activity"
  end

  @open_paths ~w(/account /pair /llms.txt /agents.md /skill.md /docs /changelog /about /privacy /terms)

  test "the public homepage links only to known pages and to anchors that exist",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")

    fleet_paths =
      for id <- Fleets.catalog_ids(),
          page <- ["", "/workspace", "/proposals", "/treasury"],
          do: Fleets.path(id) <> page

    for href <- attribute(html, "a", "href"),
        href != "/",
        not String.starts_with?(href, "https://") do
      case String.split(href, "#", parts: 2) do
        ["", anchor] -> assert anchor in anchors
        [path] -> assert URI.parse(path).path in (@open_paths ++ fleet_paths)
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

  # What the homepage's producer does as the site starts and on each pass.
  defp read_fleets, do: FleetNow.read(@classic)

  # Something a Key made public in Classic, by default in `general`.
  defp make_public!(attrs) do
    Publication
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(%{fleet_id: @classic, project: "general", author_wallet: @owner}, attrs),
      actor: %Actors.System{}
    )
    |> Ash.create!()
  end

  defp page_path(n),
    do: Keyfleet.Notebooks.result_path("nb-0123456789abcdef", "run_#{n}", 1_790_000_000_000 + n)

  # A post `@owner` wrote as Key `key` in Classic's general room, kept as the
  # room's store keeps one; answers its place in the room as one post's span.
  defp post!(key, body) do
    Rooms.bootstrap_rooms!([@classic])
    room = Rooms.get_room!(@classic, "general", authorize?: false)
    seq = Rooms.Sequence.next!(room.id)

    Repo.insert_all(
      "messages",
      [
        %{
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          seq: seq,
          fleet_id: @classic,
          room_id: Ecto.UUID.dump!(room.id),
          kind: "post",
          in_key_thread: false,
          author_kind: "human",
          author_wallet: @owner,
          as_key: key,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: "keyfleet_app"
    )

    %{from_seq: seq, to_seq: seq}
  end

  # A fleet the site has never read, as just after it starts, then read once.
  defp first_read(fleet_id) do
    SharedReading.delete(FleetNow.key(fleet_id))
    FleetNow.read(fleet_id)
  end

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
