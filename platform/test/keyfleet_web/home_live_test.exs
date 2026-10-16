defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.Components.SendAgent
  alias Phoenix.Socket.Broadcast

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - while Classic is coming soon, "Buy Next Key" and the card's tag name Key 1
  #   and its price, but the button says it can't be pressed, with "Sales open
  #   soon" beside it, links nowhere, and the header offers no Get a Key
  # - once Classic is on sale, "Buy Next Key" opens its page with Get a Key
  #   pressed, and it and the card's tag name the Key on offer and its price
  #   after the Keys sold
  # - once every Classic Key is sold, the button can't be pressed and says so
  # - the Club shows its newest open goal and featured item once connected,
  #   and the first render reads neither; a coming-soon Club reads nothing
  # - a Club read that fails is said to have failed and never shown as zero
  # - a burst of notices is answered by one refresh of each fleet it names
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

  test "once Classic is on sale, Buy Next Key opens its page at the Key on offer",
       %{conn: conn} do
    for token_id <- 1..3, do: issue!(@classic, token_id)

    {:ok, view, _html} = live(conn, "/")

    price = Keyfleet.Fleets.Presets.progress(@classic, 3).next_price

    assert has_element?(view, ~s(a#home-buy-next-key[href="/classic/1?buy"]), "Buy Next Key")
    assert text(view, "#home-buy-price") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-tag") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-why") == ""
    assert text(view, "#home-classic-sold") == "3"
  end

  test "once every Classic Key is sold, Buy Next Key can't be pressed and says so",
       %{conn: conn} do
    issue!(@classic, 1024)

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ~s(button#home-buy-next-key[aria-disabled="true"]))
    assert text(view, "#home-buy-why") == "1,024/1,024 Keys sold"
  end

  test "the Club shows its newest open goal and what it features, once connected",
       %{conn: conn} do
    goal("Sell the first audit", %{"open_questions" => ["Who pays for it?"]})
    Workspace.edit(@club, goal("Ship the site"), %{"status" => "dropped"})

    static = conn |> get("/") |> html_response(200)
    assert attribute(static, "[data-fleet-trying]", "class") == []

    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)

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
    render_async(view, 3_000)

    assert text(view, "#home-club [data-fleet-soon]") == "Opens soon"
    refute has_element?(view, "#home-club [data-fleet-who]")
  end

  test "a Club read that fails is said to have failed, never zero, and the page stays up",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)
    refute has_element?(view, "[data-fleet-failed]")

    # Renamed inside the test's own transaction, so the next reads fail the way
    # a database that refuses them does; the rename ends with the test.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.agent_profiles RENAME TO agent_profiles_away"
    )

    log =
      capture_log(fn ->
        send(view.pid, {:refresh, @club})
        render(view)
        render_async(view, 3_000)
      end)

    assert text(view, "#home-club [data-fleet-failed]") == "Couldn't read this fleet just now"
    assert log =~ "failed"
    assert Process.alive?(view.pid)
  end

  test "a first Club read that fails shows the failure, never zero", %{conn: conn} do
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.agent_profiles RENAME TO agent_profiles_away"
    )

    capture_log(fn ->
      {:ok, view, _html} = live(conn, "/")
      render_async(view, 3_000)

      assert has_element?(view, "#home-club [data-fleet-failed]")
      assert text(view, "#home-club [data-fleet-who]") == ""
    end)
  end

  test "the command box shows the homepage instruction and copies what it shows",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "#home-instruction-copy", "data-copy-text") ==
             [SendAgent.home_instruction()]

    assert text(view, "#home-instruction") == SendAgent.home_instruction()
  end

  test "a burst of notices is answered by one refresh of each fleet", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, 3_000)

    # Watch the pauses the page sets before reading a fleet again.
    :erlang.trace_pattern({:erlang, :send_after, 3}, true, [:global])
    :erlang.trace(view.pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({:erlang, :send_after, 3}, false, [:global]) end)

    send(view.pid, {:graph_notable, @club})
    send(view.pid, {:graph_notable, @club})
    send(view.pid, {:proposals_changed, @club})
    send(view.pid, {:keys_changed, @classic, [1]})

    send(view.pid, %Broadcast{
      event: "key_activity",
      payload: %{fleet_id: @classic, token_ids: [1]}
    })

    render(view)

    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @club}]}}
    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @classic}]}}
    refute_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, _}]}}, 100

    # Once the fleet has read again, its next notice sets a pause of its own.
    send(view.pid, {:refresh, @club})
    send(view.pid, {:graph_notable, @club})
    render(view)

    assert_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, @club}]}}
    refute_receive {:trace, _, :call, {:erlang, :send_after, [_, _, {:refresh, _}]}}, 100
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
