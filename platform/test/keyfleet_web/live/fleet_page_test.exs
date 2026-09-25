defmodule KeyfleetWeb.Live.FleetPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Chain.{OwnershipLog, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.WorkspacePage

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @issued 150
  @owner "0x" <> String.duplicate("a", 40)
  @stranger "0x" <> String.duplicate("b", 40)
  @operator "0x" <> String.duplicate("c", 40)
  @contract "0x" <> String.duplicate("7", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()
    ChainHelpers.open_cursor!(@fleet)

    for token_id <- 1..@issued, do: issue!(@fleet, token_id)

    %{conn: signed_in(conn)}
  end

  # A change reaches the page as a message already waiting for it. The page
  # answers a render only after the messages before it, so once the render
  # returns, whatever the page pushed for the change is already here.
  defmacrop assert_pushed(view, event, payload) do
    quote do
      render(unquote(view))
      assert_push_event(unquote(view), unquote(event), unquote(payload), 0)
    end
  end

  # However many keys a fleet has issued, the page reads one page of them; the
  # count it shows comes from counting, not from reading every key.
  test "keys are listed a hundred at a time while the count covers them all", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    {rows, {:ok, view, html}} = rows_read_during(fn -> live(conn, @path) end)

    assert Enum.max(rows) <= 101
    assert html =~ "150 of"
    # Key 151 opens level 9, whose price is the first to round up.
    assert html =~ "Key 151, 42.99817 USDC"
    assert text(view, "#fleet-sales") == "150 of 46,365 keys sold · next key 42.99817 USDC"
    assert shown_keys(view) == Enum.to_list(1..100)
    refute has_element?(view, "#fleet-keys-previous")

    view |> element("#fleet-keys-next") |> render_click()
    assert shown_keys(view) == Enum.to_list(101..150)
    refute has_element?(view, "#fleet-keys-next")

    view |> element("#fleet-keys-previous") |> render_click()
    assert shown_keys(view) == Enum.to_list(1..100)
    refute has_element?(view, "#fleet-keys-previous")
    assert has_element?(view, "#fleet-keys-next")
  end

  test "rooms are listed by the names they go by", %{conn: conn} do
    Keyfleet.Rooms.bootstrap_rooms!()

    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic = 'Hull survey', topic_set_by = $1, " <>
        "topic_set_at = now() WHERE fleet_id = $2 AND slug = 'open-1'",
      [@owner, @fleet]
    )

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/open-1"]), "Hull survey")
    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/open-2"]), "Open room 2")
    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/general"]), "General")
    refute render(view) =~ "Open room 1"
  end

  test "the bar opens the rooms and how the fleet works, both closed to start", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(
             view,
             ~s(#fleet-rooms-toggle[aria-expanded="false"][aria-controls="fleet-rooms"])
           )

    assert has_element?(view, "#fleet-rooms[hidden]")

    assert has_element?(
             view,
             ~s(#fleet-about-toggle[aria-expanded="false"][aria-controls="fleet-about"])
           )

    assert has_element?(view, "#fleet-about[hidden]")

    assert text(view, "#fleet-about") =~
             "When a level sells out, the holders of the level before it are paid back"

    assert has_element?(
             view,
             ~s(#fleet-about a#fleet-contract-link[href="https://basescan.org/address/#{@contract}"][title="#{@contract}"])
           )

    assert has_element?(view, ~s(#fleet-workspace-link[href="#{@path}/workspace"]))
    assert has_element?(view, ~s(#fleet-proposals-link[href="#{@path}/proposals"]))
    assert has_element?(view, ~s(.fleet-bar__nav a[href="#fleet-keys"]), "List of keys")
  end

  test "a page name that is not one of the fleet's keys is a page that doesn't exist", %{
    conn: conn
  } do
    assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, @path <> "?after=nonsense") end
  end

  # A fleet with no contract has sold nothing and has no price to show.
  test "a fleet not yet deployed shows no sales figures or price", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Not on Base yet"
    assert text(view, "#fleet-sales") == "Not on sale yet"
    refute has_element?(view, "#fleet-progress-title")
    refute html =~ "Next key"

    # In place of the map, a still picture of it as it will open.
    assert has_element?(
             view,
             ~s(#fleet-preview-#{@fleet}[phx-hook="FleetPreview"][data-layout="fibonacci"][data-minted="0"])
           )
  end

  # Until the fleet has been read up to now, the figures would run low, so
  # the page says they are catching up instead of showing them.
  test "a fleet whose sales are still being read shows no figures", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Sales figures are catching up."
    assert text(view, "#fleet-sales") == "Sales figures are catching up"
    refute html =~ "Keys issued"
    refute has_element?(view, ".fleet-facts dt", "Next key")
    assert shown_keys(view) == Enum.to_list(1..100)
  end

  describe "buying the next key" do
    # Key 151 opens level 9, where a wallet may hold 8 keys.
    test "offers the next key's number, exact price and level", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#buy-key-number") == "151"
      assert text(view, "#buy-key-price") == "42.99817 USDC"
      assert text(view, "#buy-key-level") == "9"
      assert render(view) =~ "One wallet may hold 8 keys of level 9."
      assert text(view, "#buy-key-button") == "Buy key 151"
      refute has_element?(view, "#buy-key-sold-out")
    end

    # The wallet is handed the fleet's own deployment and the contract's own
    # price in atomic USDC, and adds the ten minutes itself when it is pressed.
    test "hands the wallet the fleet's deployment and the exact price", %{conn: conn} do
      fleet = deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)

      assert order(view) == %{
               "phx-hook" => "BuyKey",
               "data-chain-id" => Integer.to_string(fleet.chain_id),
               "data-fleet" => fleet.contract_address,
               "data-usdc" => fleet.usdc_address,
               "data-price" => Integer.to_string(Presets.progress(@fleet, @issued).next_price),
               "data-price-label" => "42.99817 USDC",
               "data-deadline-seconds" => "600",
               "data-signed-in" => Jason.encode!([@owner])
             }

      assert order(view)["data-price"] == "42998170"
      assert fleet.usdc_address == @usdc
      assert fleet.contract_address == @contract
    end

    test "a fleet without levels offers its key with no level", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_classic")

      assert text(view, "#buy-key-number") == "1"
      assert text(view, "#buy-key-price") == "10 USDC"
      assert order(view)["data-price"] == "10000000"
      refute has_element?(view, "#buy-key-level")
      refute html =~ "One wallet may hold"
    end

    test "a sold-out fleet says so and offers nothing to buy", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..144, do: issue!("fleet_tech_classic", token_id)

      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")

      assert text(view, "#buy-key-sold-out") == "All 144 keys in this fleet have been sold."
      refute has_element?(view, "#buy-key-offer")
      refute has_element?(view, "#buy-key-button")
    end

    # The buyer's messages about their purchases stay when the last key sells
    # while the page is open.
    test "a fleet that sells out while open keeps the buyer's messages", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..143, do: issue!("fleet_tech_classic", token_id)
      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")
      assert text(view, "#buy-key-number") == "144"

      issue!("fleet_tech_classic", 144)
      send(view.pid, {:keys_changed, "fleet_tech_classic", [144]})

      assert text(view, "#buy-key-sold-out") == "All 144 keys in this fleet have been sold."
      refute has_element?(view, "#buy-key-button")
      assert has_element?(view, ~s(#buy-key-order[phx-hook="BuyKey"] > #buy-key-status))
    end

    # Stopping here would hold back a press the contract can answer: a key
    # that has since cost more is refused, and no USDC is taken.
    test "a fleet whose sales are still being read still offers the key, and says the price may have moved",
         %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#buy-key-number") == "151"

      assert text(view, "#buy-key-price-may-move") ==
               "Sales are still being counted, so this price may already have gone up. If it has, the purchase is refused and no USDC is taken, though your wallet still pays the Base network fee for trying."

      assert has_element?(view, "#buy-key-button")
    end

    test "a fleet not yet deployed offers nothing to buy", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#buy-key")
    end
  end

  describe "a referral link" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      :ok
    end

    test "carries a well-formed address into the purchase and names it", %{conn: conn} do
      ref = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf12"

      {:ok, view, _html} = live(conn, @path <> "?ref=" <> ref)

      assert order(view)["data-referrer"] == String.downcase(ref)
      assert text(view, "#buy-key-referrer") == "Referred by 0xabcd…ef12"
      refute has_element?(view, "#buy-key-referral-refused")
    end

    test "that isn't an address is left out, and the buyer is told", %{conn: conn} do
      for ref <- [
            "0x1234",
            "bob",
            "0x" <> String.duplicate("g", 40),
            "0x" <> String.duplicate("a", 41)
          ] do
        {:ok, view, _html} = live(conn, @path <> "?" <> URI.encode_query(ref: ref))

        refute Map.has_key?(order(view), "data-referrer")
        refute has_element?(view, "#buy-key-referrer")

        assert text(view, "#buy-key-referral-refused") ==
                 "The referral in this link isn’t a wallet address, so this purchase has no referrer."
      end

      {:ok, view, _html} = live(conn, @path <> "?ref[]=" <> @owner)
      refute Map.has_key?(order(view), "data-referrer")
      assert has_element?(view, "#buy-key-referral-refused")
    end

    # The contract credits any referrer, the buyer's own wallet included.
    test "naming the buyer's own wallet is carried as it is", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?ref=" <> @owner)

      assert order(view)["data-referrer"] == @owner
      refute has_element?(view, "#buy-key-referral-refused")
    end

    # The contract reads the zero address as no referral.
    test "naming the zero address is no referral", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?ref=0x" <> String.duplicate("0", 40))

      refute Map.has_key?(order(view), "data-referrer")
      refute has_element?(view, "#buy-key-referrer")
      refute has_element?(view, "#buy-key-referral-refused")
    end

    test "stays with the page while the buyer pages through keys", %{conn: conn} do
      ref = "0x" <> String.duplicate("b", 40)
      {:ok, view, _html} = live(conn, @path <> "?ref=" <> ref)

      view |> element("#fleet-keys-next") |> render_click()
      assert shown_keys(view) == Enum.to_list(101..150)
      assert order(view)["data-referrer"] == ref

      view |> element("#fleet-keys-previous") |> render_click()
      assert order(view)["data-referrer"] == ref
    end
  end

  describe "the key map" do
    # Each fleet draws its keys in its own shape, and only once it is deployed.
    test "every fleet's map draws its own layout", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#fleet-map")

      for {fleet_id, layout} <- [
            {"fibonacci_syndicate", "fibonacci"},
            {"fibonacci_cascade", "fibonacci"},
            {"fleet_tech_classic", "classic"},
            {"fleet_tech_accelerant", "accelerant"}
          ] do
        deploy!(fleet_id)
        ChainHelpers.seed_cursor!(fleet_id)
        {:ok, view, _html} = live(conn, "/app/fleets/#{fleet_id}")

        assert has_element?(
                 view,
                 ~s(#key-map-#{fleet_id}[phx-hook="KeyMap"][data-layout="#{layout}"])
               )
      end
    end

    # Level 9 holds key 151, the next on sale, so the map goes to levels 1 to 9
    # and level 10 after it.
    test "offers the next key, the viewer's keys and each level the map draws", %{
      conn: conn
    } do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#key-map-next", "Next key")
      assert has_element?(view, "#key-map-mine", "Your keys")

      assert option_values(view, "#key-map-level-choice option") ==
               Enum.map(1..10, &to_string/1)

      {:ok, view, _html} = live(build_conn(), @path)
      refute has_element?(view, "#key-map-mine")

      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")
      refute has_element?(view, "#key-map-level")
    end

    # Every sold key's two marks travel as bitsets small enough to send at the
    # largest fleet's size.
    test "loads with the keys the viewer holds and the keys agents run", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      issue!(@fleet, 151, @stranger)
      pair!(7)

      {:ok, view, _html} = live(conn, @path)
      render_hook(view, "keymap_ready", %{})

      assert_reply(view, %{minted: 151, max_supply: 46_365, mine: mine, agent: agent} = reply)
      assert byte_size(Jason.encode!(reply)) <= 20_000
      assert marked(mine) == Enum.to_list(1..150)
      assert marked(agent) == [7]
    end

    test "someone signed out holds none of the keys", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      assert {:ok, _view, _html} = live(conn, @path)

      {:ok, view, _html} = live(build_conn(), @path)
      render_hook(view, "keymap_ready", %{})

      assert_reply(view, %{mine: mine})
      assert Base.decode64!(mine) == <<0::size(5_796 * 8)>>
    end

    # Every key sold and the next one can be chosen; the choice goes into the
    # address with the key list's page, and back and forward move through it.
    test "a key chosen goes into the address, and back and forward follow it", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      second_page = view |> element("#fleet-keys-next") |> render() |> href()
      view |> element("#fleet-keys-next") |> render_click()
      assert_patch(view, second_page)

      render_hook(view, "select_key", %{"token_id" => 151})
      assert_patch(view, second_page <> "&key=151")
      assert text(view, "#key-map-selected") == "Key 151 chosen."
      assert has_element?(view, ~s(#key-map-fibonacci_cascade[data-selected="151"]))

      for refused <- [0, 152, -1, "12", 1.5, nil] do
        render_hook(view, "select_key", %{"token_id" => refused})
        refute_patched(view)
      end

      # Key 12 is sold, so its profile asks the chain what it has waiting.
      StubClient.put_chain(chain_head(1_000), [])
      render_patch(view, @path <> "?key=12")
      assert_push_event(view, "keymap:select", %{token_id: 12})
      assert text(view, "#key-map-selected") == "Key 12 chosen."
      assert has_element?(view, "#fleet-keys-next[href$='&key=12']")

      render_patch(view, @path <> "?key=152")
      assert_push_event(view, "keymap:select", %{token_id: nil})
      assert text(view, "#key-map-selected") == "No key chosen yet."
    end

    # A key sold, moved or paired reaches an open page as that key's new marks.
    test "a key sold by the chain reader reaches the map as a change", %{conn: conn} do
      fleet = deploy!("fleet_tech_accelerant", 5_000_000)
      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_accelerant")

      StubClient.put_chain(chain_head(5_000_010), [
        ownership_log(1, 1, @owner, 5_000_003),
        ownership_log(2, 1, @stranger, 5_000_004)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_pushed(view, "keymap:patch", %{minted: 2, keys: [[1, 1], [2, 0]]})
      assert text(view, "#fleet-progress-title + dl") =~ "Keys issued 2 of 2,000"
      assert text(view, "#fleet-sales") =~ "2 of 2,000 keys sold"

      StubClient.put_chain(chain_head(5_000_020), [
        ownership_log(1, 1, @owner, 5_000_003),
        ownership_log(2, 1, @stranger, 5_000_004),
        ownership_log(1, 2, @stranger, 5_000_015)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_pushed(view, "keymap:patch", %{minted: 2, keys: [[1, 0]]})
    end

    test "an agent starting or stopping on a key reaches the map as a change", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)

      pairing = pair!(7)
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 3]]})

      Keys.detach_operator!(pairing, %{}, actor: owner())
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 1]]})

      pairing = pair!(7)
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 3]]})

      Keys.step_down!(pairing, %{}, actor: operator())
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 1]]})
    end

    test "more than 2,000 keys changed at once tells the map to load again", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)

      send(view.pid, {:keys_changed, @fleet, Enum.to_list(1..2_000)})
      assert_pushed(view, "keymap:patch", %{keys: keys})
      assert length(keys) == 2_000

      send(view.pid, {:keys_changed, @fleet, Enum.to_list(1..2_001)})
      assert_pushed(view, "keymap:reset", %{})
    end

    test "a change in another fleet leaves the page as it is", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      shown = render(view)

      send(view.pid, {:keys_changed, "fibonacci_syndicate", [7, 151]})

      # Rendered first, so the page has handled the change by the time its
      # pushes are checked.
      assert render(view) == shown
      refute_push_event(view, "keymap:patch", _patch, 0)
      refute_push_event(view, "keymap:reset", _reset, 0)
    end

    # The key list reads its page again only when a changed key is on it, and
    # a key sold onto the last page joins it.
    test "the key list shows a changed key's new holder when that key is on the page", %{
      conn: conn
    } do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      assert text(view, "#fleet-key-7") =~ "Held by 0xaaaa…aaaa"

      move!(7, @stranger)
      send(view.pid, {:keys_changed, @fleet, [120]})
      assert_pushed(view, "keymap:patch", %{keys: [[120, 1]]})
      assert text(view, "#fleet-key-7") =~ "Held by 0xaaaa…aaaa"

      send(view.pid, {:keys_changed, @fleet, [7]})
      assert_pushed(view, "keymap:patch", %{keys: [[7, 0]]})
      assert text(view, "#fleet-key-7") =~ "Held by 0xbbbb…bbbb"
      assert shown_keys(view) == Enum.to_list(1..100)

      second_page = view |> element("#fleet-keys-next") |> render() |> href()
      view |> element("#fleet-keys-next") |> render_click()
      assert_patch(view, second_page)

      issue!(@fleet, 151, @stranger)
      send(view.pid, {:keys_changed, @fleet, [151]})
      assert_pushed(view, "keymap:patch", %{minted: 151, keys: [[151, 0]]})
      assert shown_keys(view) == Enum.to_list(101..151)
      assert text(view, "#buy-key-number") == "152"
    end

    test "a key in the address that isn't one on the map is no choice", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      for key <- ["abc", "-1", "0", "152", "99999999999999999999999", "1.5", ""] do
        {:ok, view, _html} = live(conn, @path <> "?" <> URI.encode_query(key: key))

        assert text(view, "#key-map-selected") == "No key chosen yet."
        refute has_element?(view, "#key-map-fibonacci_cascade[data-selected]")
      end
    end
  end

  # The page names the signed-in wallets so the button can say when the
  # connected wallet is another; the press still goes to the connected one.
  test "Buy carries the signed-in wallets for its wallet note, and none when signed out", %{
    conn: conn
  } do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, _html} = live(conn, @path)
    assert order(view)["data-signed-in"] == Jason.encode!([@owner])
    assert has_element?(view, "#buy-key-order #buy-key-wallet-note[data-wallet-note]")

    # Nothing inside, not even a space, so the page's rule hides it until
    # there is something to say.
    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#buy-key-wallet-note")
           |> LazyHTML.child_nodes()
           |> Enum.empty?()

    {:ok, view, _html} = live(init_test_session(build_conn(), %{}), @path)
    assert order(view)["data-signed-in"] == "[]"
    assert has_element?(view, "#buy-key-order #buy-key-wallet-note[data-wallet-note]")
  end

  # The button's only job is to reach the wallet, whatever the page shows.
  test "the Buy button is never disabled", %{conn: conn} do
    deploy!()

    pages = [
      {fn -> ChainHelpers.seed_cursor!(@fleet) end, conn, @path},
      {fn -> :ok end, conn, @path <> "?ref=" <> @owner},
      {fn -> :ok end, conn, @path <> "?ref=nonsense"},
      {fn -> :ok end, init_test_session(build_conn(), %{}), @path},
      {fn -> ChainHelpers.seed_cursor!(@fleet, head_block: 5_000) end, conn, @path}
    ]

    for {arrange, conn, path} <- pages do
      arrange.()
      {:ok, view, _html} = live(conn, path)

      [button] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#buy-key-button")
        |> Enum.to_list()

      attributes = button |> LazyHTML.attributes() |> hd() |> Map.new()

      refute Map.has_key?(attributes, "disabled")
      refute Map.has_key?(attributes, "aria-disabled")
      refute Map.has_key?(attributes, "inert")
    end
  end

  # A key bought reaches the open page when the chain reader records it: the
  # list, the sales figures, the map and the next key on offer all move on.
  test "a key bought appears once the chain reader records it", %{conn: conn} do
    fleet = deploy!("fleet_tech_accelerant", 5_000_000)
    {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_accelerant")
    assert text(view, "#buy-key-number") == "1"

    StubClient.put_chain(chain_head(5_000_010), [ownership_log(1, 1, @owner, 5_000_003)])
    assert Scanner.step(fleet, StubClient) == :ok

    assert_pushed(view, "keymap:patch", %{minted: 1, keys: [[1, 1]]})
    assert text(view, "#buy-key-number") == "2"
    assert text(view, "#fleet-progress-title + dl") =~ "Keys issued 1 of 2,000"
    assert shown_keys(view) == [1]
  end

  describe "what's happening" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      Rooms.bootstrap_rooms!()
      :ok
    end

    test "a post appears once the page reads the fleet again, its words as text", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, ~s(#fleet-now-list li[data-kind="post"]))

      post =
        Rooms.send_message!(
          %{
            fleet_id: @fleet,
            slug: "general",
            body: "<b>Hull</b> <script>alert(1)</script>\u0007\u202Esurvey\u2066 done",
            idempotency_key: Ash.UUID.generate()
          },
          actor: owner()
        )

      # The notice of the post came first; the message stands in for the wait.
      send(view.pid, {:refresh_activity, @fleet})

      line = "#fleet-now-posts-#{post.id}[data-kind=\"post\"]"
      assert has_element?(view, ~s(#{line} a[data-key="1"]))
      assert has_element?(view, ~s(#{line} a[data-room="general"][href="#{@path}/rooms/general"]))
      refute has_element?(view, "#fleet-now-list b")
      refute has_element?(view, "#fleet-now-list script")
      assert text(view, line) =~ "<b>Hull</b> <script>alert(1)</script>"

      # No character that can't be seen, or that reverses the text around it.
      html = view |> element("#fleet-now-list") |> render()
      refute html =~ ~r/[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}-\x{9F}\p{Cf}]/u
    end

    test "a new item lands on top after a read, with the earlier ones below it", %{conn: conn} do
      now = DateTime.utc_now()
      line!("general", 1, now)
      {:ok, view, _html} = live(conn, @path)
      before = now_items(view)

      line!("coding", 0, now)
      send(view.pid, {:refresh_activity, @fleet})

      assert [_new | ^before] = now_items(view)
    end

    test "a burst of notices is read once, after a pause", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      line!("general", 0, DateTime.utc_now())

      {one_read, _} =
        lines_read_during(fn ->
          send(view.pid, {:refresh_activity, @fleet})
          render(view)
        end)

      assert one_read > 0
      line!("coding", 0, DateTime.utc_now())

      {burst, _} =
        lines_read_during(fn ->
          send(view.pid, {:proposals_changed, @fleet})
          send(view.pid, {:graph_head, @fleet, "log", 9})
          send(view.pid, {:keys_changed, @fleet, [7]})
          render(view)
          Process.sleep(2_200)
          render(view)
        end)

      assert burst == one_read
    end

    test "notices from another fleet read nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      # Written without a notice, so only a read the page makes shows it; and
      # written now, after the keys were sold, so it tops the first page.
      line!("general", 0, DateTime.utc_now())

      other = "fibonacci_syndicate"
      send(view.pid, {:proposals_changed, other})
      send(view.pid, {:graph_head, other, "log", 9})
      send(view.pid, {:keys_changed, other, [7]})
      Process.sleep(2_200)
      refute has_element?(view, ~s(#fleet-now-list li[data-kind="post"]))
    end

    test "a wait begun in one fleet reads nothing once the page shows another", %{conn: conn} do
      other = "fibonacci_syndicate"
      ChainHelpers.open_cursor!(other)
      {:ok, view, _html} = live(conn, @path)

      send(view.pid, {:proposals_changed, @fleet})
      render_patch(view, "/app/fleets/#{other}")
      line!("general", 0, DateTime.utc_now(), other)
      send(view.pid, {:refresh_activity, @fleet})
      refute has_element?(view, ~s(#fleet-now-list li[data-kind="post"]))

      # The other fleet's own notice still starts its own wait.
      send(view.pid, {:proposals_changed, other})
      Process.sleep(2_200)
      assert has_element?(view, ~s(#fleet-now-list li[data-kind="post"]))
    end

    test "Show earlier adds older items below, up to five pages, then points elsewhere",
         %{conn: conn} do
      now = DateTime.utc_now()
      # Posts turn about between two rooms, so each is an item of its own.
      for n <- 1..200, do: line!(if(rem(n, 2) == 0, do: "general", else: "coding"), n, now)

      {:ok, view, _html} = live(conn, @path)
      first = now_items(view)
      refute has_element?(view, "#fleet-now-elsewhere")

      view |> element("#fleet-now-earlier") |> render_click()
      both = now_items(view)

      assert Enum.take(both, length(first)) == first
      assert length(both) > length(first)
      assert length(both) == length(Enum.uniq(both))

      for _ <- 1..3, do: view |> element("#fleet-now-earlier") |> render_click()

      refute has_element?(view, "#fleet-now-earlier")
      assert has_element?(view, ~s(#fleet-now-elsewhere a[href="#{@path}/rooms/general"]))
      assert has_element?(view, ~s(#fleet-now-elsewhere a[href="#{@path}/workspace"]))
      assert has_element?(view, ~s(#fleet-now-elsewhere a[href="#{@path}/proposals"]))
    end

    # The panels share one place beside the map: each button opens its own
    # panel, closes the other two, so none ever covers another, and takes the
    # reader to its heading.
    test "the panels beside the map open one at a time, What's happening first", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s{#fleet-now:not([hidden])[phx-hook="OpenWhenWide"]})
      assert has_element?(view, ~s(#fleet-now-toggle[aria-expanded="true"]))
      assert has_element?(view, "#fleet-about[hidden]")
      assert has_element?(view, "#fleet-who[hidden]")

      panels = ["fleet-now", "fleet-about", "fleet-who"]

      for panel <- panels do
        commands = click_commands(view, "##{panel}-toggle")
        assert ["toggle_attr", %{"attr" => ["hidden", "hidden"], "to" => "##{panel}"}] in commands
        assert ["focus", %{"to" => "##{panel}-title"}] in commands
        assert has_element?(view, ~s(##{panel}-title[tabindex="-1"]))

        for other <- panels -- [panel] do
          assert ["set_attr", %{"attr" => ["hidden", "hidden"], "to" => "##{other}"}] in commands
        end
      end
    end
  end

  describe "trying now" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      Workspace.open_log(@fleet)
      :ok
    end

    test "an open goal shows with its tasks, each task's key linked", %{conn: conn} do
      pair!(12)
      goal = goal!("Sell the first audit")
      task = task!("Draft the price", %{"progress" => "doing", "assignee_key" => 12})
      Workspace.link(@fleet, task, goal, "implements")
      unclaimed = task!("Find a buyer", %{"progress" => "doing"})

      {:ok, view, _html} = live(conn, @path)

      row = ~s(#fleet-trying li[data-goal="#{goal}"])
      assert has_element?(view, ~s(#{row} a[data-item-link="#{goal}"][href="#{item_path(goal)}"]))

      task_row = ~s(#{row} li[data-task="#{task}"])

      assert has_element?(
               view,
               ~s(#{task_row} a[data-item-link="#{task}"][href="#{item_path(task)}"])
             )

      assert has_element?(view, ~s(#{task_row} a[data-key="12"]), "Orbit runner")
      assert has_element?(view, ~s(#fleet-trying-taken li[data-task="#{task}"] a[data-key="12"]))
      refute has_element?(view, ~s(#fleet-trying-taken li[data-task="#{unclaimed}"]))
      refute has_element?(view, "#fleet-trying-empty")
    end

    test "a goal marked achieved is gone once the page reads the fleet again", %{conn: conn} do
      goal = goal!("Sell the first audit")
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, ~s(#fleet-trying li[data-goal="#{goal}"]))

      Workspace.edit(@fleet, goal, %{"status" => "achieved"})
      send(view.pid, {:graph_head, @fleet, "log_fixture", 9})
      # The notice starts the wait; the message stands in for its end.
      send(view.pid, {:refresh_activity, @fleet})

      refute has_element?(view, ~s(#fleet-trying li[data-goal="#{goal}"]))
      assert has_element?(view, "#fleet-trying-empty")
    end

    test "a problem raised with an item shows until it is unlinked", %{conn: conn} do
      goal = goal!("Sell the first audit")
      finding = finding!("No buyers")
      link = Workspace.link(@fleet, finding, goal, "contradicts")

      {:ok, view, _html} = live(conn, @path)

      problem = ~s(#fleet-trying-problems li[data-problem="#{link}"])
      assert has_element?(view, ~s(#{problem} a[data-item-link="#{goal}"]))
      assert has_element?(view, ~s(#{problem} a[data-item-link="#{finding}"]))

      Workspace.unlink(@fleet, link)
      send(view.pid, {:refresh_activity, @fleet})

      refute has_element?(view, ~s(#fleet-trying li[data-problem="#{link}"]))
    end

    test "what members wrote shows as text, with nothing that can't be seen", %{conn: conn} do
      written = "<b>Hull</b> <script>alert(1)</script>\u0007\u202Esurvey\u2066 done"

      goal = goal!(written, %{"open_questions" => [written]})
      task = task!(written, %{"progress" => "doing", "assignee_key" => 12})
      Workspace.link(@fleet, task, goal, "implements")
      Workspace.link(@fleet, finding!(written), goal, "contradicts")

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s(#fleet-trying li[data-goal="#{goal}"]))
      assert has_element?(view, "#fleet-trying-question")
      assert has_element?(view, "#fleet-trying-findings li")
      refute has_element?(view, "#fleet-trying b")
      refute has_element?(view, "#fleet-trying script")
      assert text(view, ~s(#fleet-trying a[data-item-link="#{task}"])) =~ "<b>Hull</b>"

      html = view |> element("#fleet-trying") |> render()
      refute html =~ ~r/[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}-\x{9F}\p{Cf}]/u
    end

    test "an item whose title has nothing to see still has a link to it", %{conn: conn} do
      goal = goal!("\u200B\u2066")

      {:ok, view, _html} = live(conn, @path)

      assert text(view, ~s(#fleet-trying a[data-item-link="#{goal}"])) != ""
    end
  end

  defp goal!(title, data \\ %{}),
    do: Workspace.create(@fleet, "goal", Map.merge(%{"title" => title, "outcome" => "O"}, data))

  defp task!(title, data),
    do: Workspace.create(@fleet, "task", Map.put(data, "title", title))

  defp finding!(title),
    do: Workspace.create(@fleet, "finding", %{"title" => title, "statement" => "S"})

  defp item_path(id), do: WorkspacePage.item_path(@fleet, id)

  defp deploy!(fleet_id \\ @fleet, deployed_block \\ 1) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: @usdc,
        deployed_block: deployed_block,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end

  defp issue!(fleet_id, token_id, owner \\ @owner) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # Key `token_id` of Cascade changes hands to `owner`.
  defp move!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 2,
        owner_wallet: owner,
        block_number: 500 + token_id,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{token_id}/2"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # An agent asks to run key `token_id` of Cascade, and its owner approves.
  defp pair!(token_id) do
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: operator())
    request = Keys.request_pairing!(@fleet, token_id, %{}, actor: operator())
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner())
  end

  defp operator,
    do: %Actors.Agent{wallet_address: @operator, chain_id: 8_453, audience: "keyfleet"}

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  # The keys a bitset from the map's first load marks.
  defp marked(bitset) do
    for <<byte <- Base.decode64!(bitset)>>, bit <- 0..7, reduce: {[], 1} do
      {keys, key} ->
        if Bitwise.band(byte, Bitwise.bsl(1, bit)) != 0,
          do: {[key | keys], key + 1},
          else: {keys, key + 1}
    end
    |> elem(0)
    |> Enum.reverse()
  end

  defp option_values(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp href(link) do
    [href] = link |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attribute("href")
    href
  end

  defp chain_head(number),
    do: %{number: number, hash: "0x" <> String.duplicate("f", 64), timestamp: DateTime.utc_now()}

  defp ownership_log(token_id, epoch, "0x" <> owner, block) do
    %{
      "address" => @contract,
      "topics" => [
        OwnershipLog.topic(),
        word(token_id),
        word(0),
        "0x" <> String.duplicate("0", 24) <> owner
      ],
      "data" => word(epoch),
      "blockNumber" => "0x" <> Integer.to_string(block, 16),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => word(block),
      "logIndex" => "0x0"
    }
  end

  defp word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")

  # The attributes the page hands the Buy button's wallet hook.
  defp order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#buy-key-order")
    |> LazyHTML.attributes()
    |> hd()
    |> Map.new()
    |> Map.drop(["id"])
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

  defp shown_keys(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fleet-key-list > li")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "fleet-key-" <> token_id -> String.to_integer(token_id) end)
  end

  # How many rows each read of the key records returned while `fun` ran.
  defp rows_read_during(fun) do
    test_pid = self()

    :telemetry.attach(
      "fleet-page-key-rows",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        with "key_attachments" <- meta.source,
             {:ok, %{num_rows: rows}} <- meta.result,
             do: send(test_pid, {:key_rows, rows})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach("fleet-page-key-rows")
      end

    {collect_rows([]), result}
  end

  defp collect_rows(rows) do
    receive do
      {:key_rows, count} -> collect_rows([count | rows])
    after
      0 -> rows
    end
  end

  # A post written as key 1 `seconds` before `now`, with no notice to anyone.
  defp line!(slug, seconds, now, fleet_id \\ @fleet) do
    room = Rooms.get_room!(fleet_id, slug)
    body = "Line #{seconds}"

    Keyfleet.Repo.insert_all(
      "messages",
      [
        %{
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          seq: System.unique_integer([:positive]),
          fleet_id: fleet_id,
          room_id: Ecto.UUID.dump!(room.id),
          kind: "post",
          in_key_thread: false,
          author_kind: "human",
          author_wallet: @owner,
          as_key: 1,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: now |> DateTime.add(-seconds) |> DateTime.to_naive()
        }
      ],
      prefix: "keyfleet_app"
    )
  end

  # How many of the fleet's lines the page reads while `fun` runs.
  defp lines_read_during(fun) do
    test_pid = self()

    :telemetry.attach(
      "fleet-page-lines",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "messages", do: send(test_pid, :lines_read)
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach("fleet-page-lines")
      end

    {count_reads(0), result}
  end

  defp count_reads(count) do
    receive do
      :lines_read -> count_reads(count + 1)
    after
      0 -> count
    end
  end

  # The ids of the lines "What's happening" shows, top to bottom.
  defp now_items(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fleet-now-list > li")
    |> LazyHTML.attribute("id")
  end

  # The page commands a button runs when pressed.
  defp click_commands(view, selector) do
    [commands] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("phx-click")

    Jason.decode!(commands)
  end

  defp signed_in(conn) do
    account =
      Accounts.register_verified!(
        "did:privy:fleet-page:#{System.unique_integer([:positive])}",
        @owner,
        [@owner],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end
