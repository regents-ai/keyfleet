defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, SharedReading}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.Components.SendAgent
  alias KeyfleetWeb.{FleetNow, KeyLinks}
  alias Phoenix.Socket.Broadcast

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - while Classic is coming soon, "Buy Next Key" and the card's tag name Key 1
  #   and its price, but the button says it can't be pressed, with "Sales open
  #   soon" beside it, links nowhere, and the header offers no Get a Key
  # - once Classic is on sale, "Buy Next Key" and the header's "Get a Key"
  #   open the "Buy Key" window, which holds the fleet's own Approve and Buy,
  #   and the button and the card's tag name the Key on offer and its price
  #   after the Keys sold
  # - once every Classic Key is sold, the button can't be pressed and says so
  # - the Club shows its newest open goal and featured item from the first
  #   render; a coming-soon Club reads nothing
  # - an open page draws again when the homepage's reading changes
  # - a Club read that fails is said to have failed and never shown as zero
  # - a burst of notices is answered by one read of each fleet it names, for
  #   every open homepage at once, and a post taken off a wall reads its fleet
  #   again
  # - each sea draws the ships of the one reading every open page shares, from
  #   the first render; the page reads no ships of its own, a new reading
  #   reaches the open page, and pressing a ship opens its Key
  # - the command box shows the homepage instruction whole and copies exactly
  #   what it shows
  # - the Markdown homepage carries the tagline as Sean wrote it, says Classic
  #   opens soon until it does, then links its page
  # - launch-gate: internal links stay on the fleets' maps, the account page,
  #   the public documents, or anchors that exist

  @classic "fleet_tech_classic"
  @club "regents_club"
  @owner "0x" <> String.duplicate("a", 40)

  setup context do
    Fleets.bootstrap_catalog!()

    unless context[:classic_undeployed] do
      ChainHelpers.deploy!(@classic)
      ChainHelpers.seed_cursor!(@classic)
    end

    unless context[:club_undeployed] do
      ChainHelpers.deploy!(@club)
      ChainHelpers.seed_cursor!(@club)
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

  @tag :classic_undeployed
  test "while Classic is coming soon, Buy Next Key can't be pressed and says why",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert has_element?(
             view,
             ~s(button#home-buy-next-key[aria-disabled="true"][aria-describedby="home-buy-why"]),
             "Buy Next Key"
           )

    assert text(view, "#home-buy-price") == "Key 1 · 10 USDC"
    assert text(view, "#home-buy-tag") == "Key 1 · 10 USDC"
    assert text(view, "#home-buy-why") == "Sales open soon"
    refute html =~ "?buy"
    refute has_element?(view, "#shell-get-key")
  end

  test "once Classic is on sale, Buy Next Key names the Key on offer and opens the Buy Key window",
       %{conn: conn} do
    for token_id <- 1..3, do: issue!(@classic, token_id)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    price = Keyfleet.Fleets.Presets.progress(@classic, 3).next_price

    assert text(view, "#home-buy-price") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-tag") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-why") == ""
    assert text(view, "#home-classic-sold") == "3"

    view |> element("button#home-buy-next-key") |> render_click()

    assert has_element?(
             view,
             ~s(dialog#home-buy-key button#home-buy-key-button[data-onchain-step="buy"])
           )

    assert has_element?(
             view,
             ~s(dialog#home-buy-key button#home-buy-key-approve[data-onchain-step="approve"])
           )

    assert has_element?(view, "dialog#home-buy-key #home-buy-key-risks")
    refute has_element?(view, "#home-buy-key-go")
  end

  test "once Classic is on sale, the header's Get a Key opens the Buy Key window", %{conn: conn} do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    view |> element("button#shell-get-key") |> render_click()

    assert has_element?(view, "dialog#home-buy-key")
  end

  test "once Classic is on sale, Buy Key opens its window with the Key cards turning",
       %{conn: conn} do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    view |> element("button#home-classic-buy") |> render_click()

    assert has_element?(view, "dialog#home-buy-key #home-buy-key-cards.rl-cards")
  end

  test "once every Classic Key is sold, Buy Next Key can't be pressed and says so",
       %{conn: conn} do
    issue!(@classic, 1024)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ~s(button#home-buy-next-key[aria-disabled="true"]))
    assert text(view, "#home-buy-why") == "1,024/1,024 Keys sold"
  end

  test "the Club shows its newest open goal and what it features, from the first render",
       %{conn: conn} do
    goal("Sell the first audit", %{"open_questions" => ["Who pays for it?"]})
    Workspace.edit(@club, goal("Ship the site"), %{"status" => "dropped"})
    read_fleets()

    static = conn |> get("/") |> html_response(200)
    assert static =~ "Trying: Sell the first audit"

    {:ok, view, _html} = live(conn, "/")

    assert text(view, "#home-club [data-fleet-trying]") == "Trying: Sell the first audit"

    assert has_element?(
             view,
             ~s(#home-club [data-fleet-featured][data-kind="open_question"]),
             "Who pays for it?"
           )

    assert has_element?(
             view,
             ~s(#home-club [data-fleet-latest][data-kind="status"]),
             "Ship the site"
           )

    assert has_element?(view, ~s(#home-club-public[href="/app/fleets/regents_club"]))
  end

  @tag :club_undeployed
  test "a coming-soon Club says so and reads nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert text(view, "#home-club [data-fleet-soon]") == "Opens soon"
    refute has_element?(view, "#home-club [data-fleet-who]")

    # Sean, 19 Oct: the Club's public page and its Keys on OpenSea show even
    # before it opens, and its section has no turning cards.
    assert has_element?(
             view,
             ~s(#home-club-public[href="/app/fleets/regents_club"]),
             "Public View"
           )

    assert has_element?(
             view,
             ~s(#home-club-opensea[href^="https://opensea.io/collection/keyfleet?"]),
             "Buy Key on OpenSea"
           )

    refute has_element?(view, "#home-club .rl-cards")
  end

  test "an open homepage draws again when the Club's reading changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "#home-club [data-fleet-trying]") == "No goal set yet"

    goal("Sell the first audit")
    FleetNow.read(@club)

    assert text(view, "#home-club [data-fleet-trying]") == "Trying: Sell the first audit"
  end

  test "a Club read that fails is said to have failed, never zero, and the page stays up",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "[data-fleet-failed]")

    # Renamed inside the test's own transaction, so the next reads fail the way
    # a database that refuses them does; the rename ends with the test.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.graph_events RENAME TO graph_events_away"
    )

    log = capture_log(fn -> FleetNow.read(@club) end)

    assert text(view, "#home-club [data-fleet-failed]") == "Couldn’t load this fleet just now."
    assert log =~ "failed"
    assert Process.alive?(view.pid)
  end

  test "a first Club read that fails shows the failure, never zero", %{conn: conn} do
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.graph_events RENAME TO graph_events_away"
    )

    capture_log(fn ->
      first_read(@club)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#home-club [data-fleet-failed]")
      assert text(view, "#home-club [data-fleet-who]") == ""
    end)
  end

  test "fleets that can't be read leave the homepage drawn, saying so for each",
       %{conn: conn} do
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.fleets RENAME TO fleets_away"
    )

    capture_log(fn ->
      first_read(@classic)
      first_read(@club)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#public-home")
      assert has_element?(view, "#home-club [data-fleet-failed]")
      refute has_element?(view, "#home-club [data-fleet-soon]")
      assert text(view, "#home-classic-sold") == "—"
      assert text(view, "#home-buy-why") == "Couldn’t read sales just now"
    end)
  end

  test "the command box shows the homepage instruction and copies what it shows",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "#home-instruction-copy", "data-copy-text") ==
             [SendAgent.home_instruction()]

    assert text(view, "#home-instruction") == SendAgent.home_instruction()
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

  # R-20261019-home-ships-shared: each open homepage read both fleets' ships
  # again for every burst of notices, and drew its seas empty until it had.
  describe "the fleets' seas" do
    test "draw the ships of the one shared reading from the first render", %{conn: conn} do
      Workspace.create(@classic, "goal", %{"title" => "Chart the bay", "outcome" => "O"}, by: 7)
      Workspace.create(@club, "goal", %{"title" => "Ship the site", "outcome" => "O"}, by: 12)
      read_fleets()

      static = conn |> get("/") |> html_response(200)
      assert crew(static, "#home-classic-sea") == [7]
      assert crew(static, "#home-club-sea") == [12]

      {:ok, _view, html} = live(conn, "/")
      assert crew(html, "#home-classic-sea") == [7]
      assert crew(html, "#home-club-sea") == [12]
    end

    test "take new ships only from the shared reading, and a ship opens its Key",
         %{conn: conn} do
      Workspace.create(@classic, "goal", %{"title" => "Chart the bay", "outcome" => "O"}, by: 7)
      Workspace.create(@club, "goal", %{"title" => "Ship the site", "outcome" => "O"}, by: 12)
      read_fleets()
      {:ok, view, _html} = live(conn, "/")

      # Saved, but not yet in the reading: the page reads no ships of its own.
      Workspace.create(@classic, "goal", %{"title" => "Map the reef", "outcome" => "O"}, by: 9)
      assert crew(render(view), "#home-classic-sea") == [7]

      FleetNow.read(@classic)
      assert crew(render(view), "#home-classic-sea") == [9, 7]
      assert crew(render(view), "#home-club-sea") == [12]

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(view, "open_ship", %{"id" => "#{@club}:12"})

      assert to == KeyLinks.key_path(@club, 12)
    end
  end

  test "the page and the Markdown homepage carry the tagline as written", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "#home-title") == "Your personal agent joins a Fleet with a Key."

    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    assert markdown =~ "\nYour personal agent joins a Fleet with a Key.\n"
    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [_, path] = Regex.run(~r{\[What it’s doing right now\]\(https?://[^/]+(/[^)]+)\)}, section)
    assert path == "/fleets/fleet_tech_classic.md"
    assert build_conn() |> get(path) |> response(200) =~ "Classic #1"
  end

  @tag :classic_undeployed
  test "the Markdown homepage says Classic opens soon until it does", %{conn: conn} do
    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "Sales open soon."
    refute section =~ "What it’s doing right now"
  end

  @open_paths ~w(/account /llms.txt /agents.md /skill.md /docs /about /contact /privacy /terms)

  test "the public homepage links only to known pages and to anchors that exist",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")
    fleet_paths = Enum.map(Fleets.catalog_ids(), &"#{Keyfleet.Fleets.path(&1)}")

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
  defp read_fleets, do: Enum.each([@classic, @club], &FleetNow.read/1)

  # A fleet the site has never read, as just after it starts, then read once.
  defp first_read(fleet_id) do
    SharedReading.delete(FleetNow.key(fleet_id))
    FleetNow.read(fleet_id)
  end

  # The Keys of the ships a sea's hook is handed, in order.
  defp crew(html, sea) do
    [json] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(sea)
      |> LazyHTML.attribute("data-harbour-crew")

    for %{"id" => id} <- Jason.decode!(json),
        do: id |> String.split(":") |> List.last() |> String.to_integer()
  end

  defp goal(title, data \\ %{}),
    do: Workspace.create(@club, "goal", Map.merge(%{"title" => title, "outcome" => "O"}, data))

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
