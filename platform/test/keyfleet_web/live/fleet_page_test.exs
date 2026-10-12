defmodule KeyfleetWeb.Live.FleetPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Chain.{OwnershipLog, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals.Actions
  alias Keyfleet.Rooms
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.WorkspacePage
  alias RegentChain.Call

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @issued 150
  @owner "0x" <> String.duplicate("a", 40)
  @stranger "0x" <> String.duplicate("b", 40)
  @agent "0x" <> String.duplicate("c", 40)
  @contract "0x" <> String.duplicate("7", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @shard_issued RegentChain.Event.topic0("ShardIssued(uint256,address,uint64,uint64)")
  @shard_ended RegentChain.Event.topic0("ShardEnded(uint256,address,address)")

  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()
    ChainHelpers.open_cursor!(@fleet)

    for token_id <- 1..@issued, do: issue!(@fleet, token_id)
    # A chain that answers no reads until a test says what it holds.
    StubClient.put_chain(chain_head(1_000), [])

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

    {rows, {:ok, view, _html}} = rows_read_during(fn -> live(conn, @path) end)

    assert Enum.max(rows) <= 101
    assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"
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
    deploy!()
    Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())

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

  # An open fleet's rooms are opened by the deploy that opens it; until then
  # its rooms menu says it has none.
  test "a fleet with no rooms yet says so in its rooms menu", %{conn: conn} do
    ChainHelpers.deploy!("fleet_tech_classic")
    {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")

    assert text(view, "#fleet-rooms") == "No rooms yet."
    refute has_element?(view, "#fleet-rooms a")
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
    assert has_element?(view, ~s(.fleet-bar__nav a[href="#fleet-keys"]), "List of Keys")
  end

  test "a page name that is not one of the fleet's keys is a page that doesn't exist", %{
    conn: conn
  } do
    deploy!()
    assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, @path <> "?after=nonsense") end
  end

  # An open fleet with no contract has sold nothing and has no price to show.
  test "a fleet not yet deployed shows no sales figures or price", %{conn: conn} do
    ChainHelpers.seed_cursor!("fleet_tech_classic")

    {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_classic")

    assert html =~ "Coming soon"
    refute has_element?(view, "#fleet-sales")
    refute has_element?(view, "#fleet-get-key")
    refute has_element?(view, "#fleet-progress-title")

    # In place of the map, a still picture of it as it will open.
    assert has_element?(
             view,
             ~s(#fleet-preview-fleet_tech_classic[phx-hook="FleetPreview"][data-layout="classic"][data-minted="0"])
           )
  end

  # Until the fleet has been read up to now, the figures would run low, so
  # the page says they are catching up instead of showing them.
  test "a fleet whose sales are still being read shows no figures", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Figures are catching up."
    assert text(view, "#fleet-sales") == "Figures are catching up · 0 agents here"
    refute html =~ "Keys issued"
    assert shown_keys(view) == Enum.to_list(1..100)
  end

  describe "a fleet coming soon" do
    # Keys issued and rooms opened make no difference: until its deployment
    # is recorded, the page offers nothing to buy and nothing to join.
    test "shows its name and that it opens later, and nothing to buy or join", %{conn: conn} do
      Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, html} = live(conn, @path)

      assert has_element?(view, "#fleet-soon h1", "Cascade #1")
      assert has_element?(view, "#fleet-soon-title", "Coming soon")
      assert has_element?(view, ~s(#fleet-soon a[href="/#fleets"]), "See the fleets")

      for id <- ~w(fleet-get-key fleet-send-agent fleet-rooms fleet-keys fleet-workspace-link
                   fleet-proposals-link fleet-progress-title fleet-now-list) do
        refute has_element?(view, "##{id}")
      end

      refute html =~ "Keys sold"
      # The header's Buy Credits dialog is on every signed-in page; the fleet offers nothing.
      refute view |> element("#route-content") |> render() =~ "USDC"
    end

    test "its rooms, workspace and proposals lead back to its page", %{conn: conn} do
      Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())

      {:ok, view, _html} = live(conn, @path)

      for page <- ~w(/rooms/general /workspace /workspace/task%231 /proposals /proposals/1) do
        assert {:error, {:live_redirect, %{to: @path}}} = live(conn, @path <> page)

        # Reached from inside the shell, the same page patches back.
        render_patch(view, @path <> page)
        assert_patch(view, @path)
        assert has_element?(view, "#fleet-soon-title", "Coming soon")
      end
    end

    test "opens once its deployment is recorded", %{conn: conn} do
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#fleet-soon-title", "Coming soon")

      deploy!()

      {:ok, view, _html} = live(conn, @path)
      assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"
      assert has_element?(view, "#fleet-get-key")
      refute has_element?(view, "#fleet-soon")
    end
  end

  describe "buying the next key" do
    # Key 151 opens level 9, whose price is the first to round up. The offer
    # heads the panel in one line, with Buy straight under it.
    test "offers the next key's number, exact price and level", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#fleet-about #buy-key-title #buy-key-offer") ==
               "Key 151 · 42.99817 USDC · Level 9"

      assert text(view, "#buy-key-tip") =~ "approves exactly 42.99817 USDC"
      assert text(view, "#buy-key-number") == "151"
      assert text(view, "#buy-key-price") == "42.99817 USDC"
      assert text(view, "#fleet-about #buy-key-order #buy-key-button") == "Buy Key 151"
      refute has_element?(view, "#buy-key-sold-out")
    end

    # The steps are built on the server for the wallet that sends them, and
    # the page has them before anyone presses: an approval of exactly the
    # price when the wallet hasn't allowed that much, then the purchase.
    test "builds Approve and Buy for the signed-in wallet once it is the active one", %{
      conn: conn
    } do
      fleet = deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 0)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "buy-key-order",
        review: review
      })

      assert review.signer == @owner
      assert review.chain.chain_id == fleet.chain_id
      assert Enum.map(review.steps, & &1.step) == ["approve", "buy"]

      [approve, buy] = review.steps
      assert approve.to == @usdc
      assert approve.data == Call.encode("approve(address,uint256)", [@contract, 42_998_170])
      assert buy.to == @contract
      assert "0x" <> _calldata = buy.data

      assert text(view, "#buy-key-order-line") == "Key 151: 42.99817 USDC."

      assert text(view, "#buy-key-order-from") == "Sending from 0xaaaa..aaaa on Base."
      refute has_element?(view, "#buy-key-approve[hidden]")
      assert has_element?(view, "#buy-key-button[disabled][aria-describedby=buy-key-button-why]")
      assert text(view, "#buy-key-button-why") == "Approve USDC first"
    end

    # A pending transaction is never a reason: Buy can be pressed as soon as
    # the approval is sent, while it is still on its way, and the steps are
    # built again once it lands.
    test "Buy can be pressed as soon as the approval is sent, and the approval's outcome is shown",
         %{
           conn: conn
         } do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 0)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner)

      assert_push_event(view, "onchain-steps:review", %{
        review: %{steps: [approve, _buy]} = review
      })

      hash = "0x" <> String.duplicate("1", 64)
      chain!(allowance: 42_998_170)
      TestChainNode.land!(hash, review, approve, "0x1")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "approve",
        "transaction_hash" => hash
      })

      refute has_element?(view, "#buy-key-button[disabled]")
      refute has_element?(view, "#buy-key-button-why")

      render_async(view)

      assert has_element?(
               view,
               "#buy-key-order-sent li[data-state=confirmed] strong",
               "Approve"
             )

      assert text(view, "#buy-key-order-sent span") == "Approved. Now press the next button."
      refute has_element?(view, "#buy-key-button[disabled]")

      # Built again for the allowance now in place: the purchase alone.
      assert_push_event(view, "onchain-steps:review", %{review: %{steps: [%{step: "buy"}]}})
      assert has_element?(view, "#buy-key-approve[hidden]")

      assert text(view, "#buy-key-order-line") == "Key 151: 42.99817 USDC."
    end

    test "a purchase that doesn't go through says why it may not have", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 42_998_170)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner)
      assert_push_event(view, "onchain-steps:review", %{review: %{steps: [buy]} = review})

      hash = "0x" <> String.duplicate("2", 64)
      chain!(allowance: 42_998_170)
      TestChainNode.land!(hash, review, buy, "0x0")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "buy",
        "transaction_hash" => hash
      })

      render_async(view)
      assert has_element?(view, "#buy-key-order-sent li[data-state=reverted] strong", "Buy Key")

      assert text(view, "#buy-key-order-sent span") == "Not bought. No USDC was taken."

      refute has_element?(view, "#buy-key-button[disabled]")
    end

    # Skill rule 3: another wallet open in the wallet app keeps the figures
    # on the account's own wallet, names both, and gets no steps to send.
    test "a wallet the account doesn't link is named, and nothing is built for it", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 0)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @stranger)

      refute_push_event(view, "onchain-steps:review", %{review: %{}})

      assert text(view, "#buy-key-order-mismatch") ==
               "Your wallet is on 0xbbbb..bbbb, which isn't linked to this account. " <>
                 "Switch to 0xaaaa..aaaa."

      assert has_element?(view, "#buy-key-order-from[hidden]")
      assert text(view, "#buy-key-order-line") == "Key 151: 42.99817 USDC."

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_failed", %{"step" => "buy", "reason" => "wallet_unavailable"})

      assert text(view, "#buy-key-order-press-note") ==
               "Your wallet is on 0xbbbb..bbbb, which isn't linked to this account. " <>
                 "Switch to 0xaaaa..aaaa. Nothing was sent."
    end

    # Costly failure: a press on the wallet panel is acted on for a sign-in
    # that has already ended elsewhere.
    test "a press after the sign-in ended elsewhere does nothing and the page moves to sign-in",
         %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 0)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner)

      assert_push_event(view, "onchain-steps:review", %{
        review: %{steps: [approve, _buy]} = review
      })

      assert conn |> get_session() |> SessionAuthority.claim() |> SessionAuthority.revoke()

      hash = "0x" <> String.duplicate("1", 64)
      TestChainNode.land!(hash, review, approve, "0x1")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "approve",
        "transaction_hash" => hash
      })

      refute has_element?(view, "#buy-key-order-sent li")
      assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign in")
    end

    test "signed out, nothing is built and a press says to sign in", %{conn: _conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 0)

      {:ok, view, _html} = live(init_test_session(build_conn(), %{}), @path)
      active!(view, @owner)

      refute_push_event(view, "onchain-steps:review", %{review: %{}})
      assert has_element?(view, "#buy-key-order-line[hidden]")
      refute has_element?(view, "#buy-key-button[disabled]")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_failed", %{"step" => "buy", "reason" => "wallet_unavailable"})

      assert text(view, "#buy-key-order-press-note") == "Sign in to send this. Nothing was sent."
    end

    test "a fleet without levels offers its key with no level", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")

      assert text(view, "#buy-key-number") == "1"
      assert text(view, "#buy-key-price") == "10 USDC"
      refute has_element?(view, "#buy-key-level")
    end

    # A purchase from a sold-out fleet is certain to fail, so Buy stays in
    # view but can't be pressed, and the count beside it says why.
    test "a sold-out fleet keeps Buy in view, not pressable, with the count sold beside it",
         %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..1_024, do: issue!("fleet_tech_classic", token_id)

      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")
      active!(view, @owner)

      assert text(view, "#buy-key-sold-out") == "1,024/1,024 Keys sold"
      assert text(view, "#buy-key-elsewhere") =~ "You can still get a Key from someone"
      assert has_element?(view, "#buy-key-offer[hidden]")
      assert has_element?(view, "#buy-key-approve[hidden]")
      assert has_element?(view, "#buy-key-button")

      assert has_element?(
               view,
               "#buy-key-button[disabled][aria-describedby=buy-key-sold-out]",
               "Buy Key"
             )

      refute has_element?(view, "#fleet-get-key")
    end

    test "a fleet with keys left has no sold-out line and Buy can be pressed", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")

      refute has_element?(view, "#buy-key-sold-out")
      refute has_element?(view, "#buy-key-elsewhere")
      refute has_element?(view, "#buy-key-button[disabled]")
    end

    # The buyer's purchases and how each landed stay when the last key sells
    # while the page is open.
    test "a fleet that sells out while open keeps the buyer's purchases", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..1_023, do: issue!("fleet_tech_classic", token_id)
      chain!(allowance: 100_000_000)
      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")
      assert text(view, "#buy-key-number") == "1,024"
      assert text(view, "#buy-key-price") == "100 USDC"

      active!(view, @owner)
      assert_push_event(view, "onchain-steps:review", %{review: %{steps: [buy]} = review})
      hash = "0x" <> String.duplicate("3", 64)
      chain!(allowance: 100_000_000)
      TestChainNode.land!(hash, review, buy, "0x1")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "buy",
        "transaction_hash" => hash
      })

      render_async(view)

      issue!("fleet_tech_classic", 1_024, @owner)
      send(view.pid, {:keys_changed, "fleet_tech_classic", [1_024]})

      assert text(view, "#buy-key-sold-out") == "1,024/1,024 Keys sold"
      assert has_element?(view, "#buy-key-button[disabled]")
      assert has_element?(view, "#buy-key-order-sent li[data-state=confirmed] strong", "Buy Key")
      assert text(view, "#buy-key-order-sent span") =~ "Done. The Key is yours"
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
               "Sales are still being counted, so this price may already have gone up. If it has, the purchase is refused and no USDC is taken, though your wallet still pays the network fee for trying."

      assert has_element?(view, "#buy-key-button")
    end

    test "a fleet not yet deployed offers nothing to buy", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#buy-key")
    end

    # "Get a key" opens the offer's panel in the one place the panels share,
    # closes the other two, and takes the reader to buying a key.
    test "Get a key opens How this fleet works at Buying a key", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)
      commands = click_commands(view, "#fleet-get-key")

      assert ["remove_attr", %{"attr" => "hidden", "to" => "#fleet-about"}] in commands

      assert ["set_attr", %{"attr" => ["aria-expanded", "true"], "to" => "#fleet-about-toggle"}] in commands

      for other <- ["fleet-now", "fleet-who"] do
        assert ["set_attr", %{"attr" => ["hidden", "hidden"], "to" => "##{other}"}] in commands

        assert ["set_attr", %{"attr" => ["aria-expanded", "false"], "to" => "##{other}-toggle"}] in commands
      end

      assert ["set_attr", %{"attr" => ["data-for", "buy"], "to" => "#fleet-about"}] in commands
      assert ["focus", %{"to" => "#buy-key-title"}] in commands
      assert has_element?(view, ~s(#fleet-about #buy-key #buy-key-title[tabindex="-1"]))
    end

    # A buyer sees what the next Key costs before pressing anything, as the
    # Buy button will name it: under the count of Keys sold on the fleet's
    # bar, and on its homepage card.
    test "the next Key and its price show before any press" do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, _html} = live(build_conn(), "/app/fleets/fleet_tech_classic")
      assert has_element?(view, "#fleet-next-key", "Key 1 · 10 USDC")

      {:ok, home, _html} = live(build_conn(), "/")

      assert render_async(home) =~
               ~r/id="home-fleet-fleet_tech_classic-next-key"[^>]*>\s*<span>Key 1 · 10 USDC/

      # The card opens the fleet's page with "Get a Key" pressed, as the header does.
      assert has_element?(
               home,
               ~s(#home-fleet-fleet_tech_classic a[href="/app/fleets/fleet_tech_classic?buy"])
             )
    end

    # The header's "Get a Key", there for everyone on the homepage and every
    # app page, lands on Classic with its own "Get a Key" pressed, then drops
    # the press from the address so the next press opens it again.
    test "the header's Get a Key lands on Classic at Buying a Key", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, home, _html} = live(build_conn(), "/")
      assert has_element?(home, ~s(#shell-get-key[href="/app/fleets/fleet_tech_classic?buy"]))

      {:ok, view, _html} = live(conn, @path)
      view |> element("#shell-get-key") |> render_click()
      assert_patch(view, "/app/fleets/fleet_tech_classic?buy")

      # Drawn already open as "Get a Key", so it shows before the page connects.
      assert has_element?(view, ~s(#fleet-about[data-for="buy"]))
      refute has_element?(view, "#fleet-about[hidden]")
      assert has_element?(view, "#fleet-now[hidden]")

      [arrival] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#fleet-get-key-on-arrival")
        |> LazyHTML.attribute("phx-mounted")

      assert Jason.decode!(arrival) ==
               click_commands(view, "#fleet-get-key") ++
                 [["patch", %{"href" => "/app/fleets/fleet_tech_classic", "replace" => true}]]
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

    # Level 9 holds key 151, the next on sale, so the map draws levels 1 to 9.
    test "offers the next key, the viewer's keys and each level the map draws", %{
      conn: conn
    } do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#key-map-next", "Next Key")
      assert has_element?(view, "#key-map-mine", "Your Keys")

      assert option_values(view, "#key-map-level-choice option") ==
               Enum.map(1..9, &to_string/1)

      {:ok, view, _html} = live(build_conn(), @path)
      refute has_element?(view, "#key-map-mine")

      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")
      refute has_element?(view, "#key-map-level")
    end

    # Every sold key's two marks travel as bitsets that reach only as far as the
    # highest key marked, so they stay small however far the fleet has grown.
    test "loads with the keys the viewer holds and the keys agents hold shards of", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      issue!(@fleet, 151, @stranger)
      shard!(7)

      {:ok, view, _html} = live(conn, @path)
      render_hook(view, "keymap_ready", %{})

      assert_reply(view, %{minted: 151, max_supply: nil, mine: mine, agent: agent} = reply)
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
      assert Base.decode64!(mine) == ""
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
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "Key 151 chosen."
      assert has_element?(view, ~s(#key-map-fibonacci_cascade[data-selected="151"]))

      for refused <- [0, 152, -1, "12", 1.5, nil] do
        render_hook(view, "select_key", %{"token_id" => refused})
        refute_patched(view)
      end

      # Key 12 is sold, so its profile asks the chain what it has waiting.
      StubClient.put_chain(chain_head(1_000), [])
      render_patch(view, @path <> "?key=12")
      assert_push_event(view, "keymap:select", %{token_id: 12})
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "Key 12 chosen."
      assert has_element?(view, "#fleet-keys-next[href$='&key=12']")

      render_patch(view, @path <> "?key=152")
      assert_push_event(view, "keymap:select", %{token_id: nil})
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "No Key chosen yet."
    end

    # A key sold, moved or given a shard reaches an open page as that key's new marks.
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
      assert text(view, "#fleet-sales") == "2 Keys sold · 0 agents here"

      StubClient.put_chain(chain_head(5_000_020), [
        ownership_log(1, 1, @owner, 5_000_003),
        ownership_log(2, 1, @stranger, 5_000_004),
        ownership_log(1, 2, @stranger, 5_000_015)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_pushed(view, "keymap:patch", %{minted: 2, keys: [[1, 0]]})
    end

    test "a shard issued, ended by its owner or stepped down from reaches the map as a change",
         %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      agent_profile!()
      {:ok, view, _html} = live(conn, @path)

      issued = shard_log(:issued, 7, 1_010)
      scan!(1_020, [issued])
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 3]]})

      ended = shard_log({:ended, @owner}, 7, 1_030)
      scan!(1_040, [issued, ended])
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 1]]})

      again = shard_log(:issued, 7, 1_050)
      scan!(1_060, [issued, ended, again])
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 3]]})

      scan!(1_080, [issued, ended, again, shard_log({:ended, @agent}, 7, 1_070)])
      assert_pushed(view, "keymap:patch", %{minted: 150, keys: [[7, 1]]})
    end

    # A shard's notice is the fleet's keys changing, so the bar counts the
    # agent as soon as its shard is issued, and stops once it ends.
    test "the bar counts an agent once its shard is issued, and stops when it ends", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      agent_profile!()
      {:ok, view, _html} = live(conn, @path)
      assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"

      issued = shard_log(:issued, 7, 1_010)
      scan!(1_020, [issued])
      assert_pushed(view, "keymap:patch", %{keys: [[7, 3]]})
      assert text(view, "#fleet-sales") == "150 Keys sold · 1 agent here"
      assert has_element?(view, "#fleet-who-list", "Orbit runner")

      scan!(1_040, [issued, shard_log({:ended, @owner}, 7, 1_030)])
      assert_pushed(view, "keymap:patch", %{keys: [[7, 1]]})
      assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"
      assert has_element?(view, "#fleet-who-empty")
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
      assert text(view, "#fleet-key-7") =~ "Held by 0xaaaa..aaaa"

      move!(7, @stranger)
      send(view.pid, {:keys_changed, @fleet, [120]})
      assert_pushed(view, "keymap:patch", %{keys: [[120, 1]]})
      assert text(view, "#fleet-key-7") =~ "Held by 0xaaaa..aaaa"

      send(view.pid, {:keys_changed, @fleet, [7]})
      assert_pushed(view, "keymap:patch", %{keys: [[7, 0]]})
      assert text(view, "#fleet-key-7") =~ "Held by 0xbbbb..bbbb"
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

        assert text(view, "#key-map-selected .key-map-selected__chosen") == "No Key chosen yet."
        refute has_element?(view, "#key-map-fibonacci_cascade[data-selected]")
      end
    end
  end

  # The fleet's own "Send your agent" asks the agent to look at this fleet.
  test "Send your agent gives an instruction naming this fleet", %{
    conn: conn
  } do
    deploy!()
    {:ok, view, _html} = live(conn, @path)
    refute has_element?(view, "#fleet-send-agent-dialog")

    view |> element(".fleet-bar #fleet-send-agent") |> render_click()

    instruction = text(view, "#fleet-send-agent-instruction")

    assert instruction ==
             "Visit keyfleet.ai and read its joining guide. Then look at the Cascade #1 fleet."

    assert has_element?(
             view,
             ~s(#fleet-send-agent-copy[data-copy-text="#{instruction}"])
           )

    render_hook(view, "close_send_agent", %{})
    refute has_element?(view, "#fleet-send-agent-dialog")
  end

  # The button's only job is to reach the wallet, whatever the page shows.
  test "the Buy button is never disabled", %{conn: conn} do
    deploy!()

    pages = [
      {fn -> ChainHelpers.seed_cursor!(@fleet) end, conn, @path},
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
      refute Map.has_key?(attributes, "phx-click")
      assert attributes["data-onchain-step"] == "buy"
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

  describe "the token launch" do
    @treasury "0x" <> String.duplicate("7e", 20)
    @factory "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e"
    @launched_token "0x" <> String.duplicate("1a", 20)
    @auction "0x" <> String.duplicate("2a", 20)
    @escrow "0x" <> String.duplicate("3a", 20)
    @strategy "0x" <> String.duplicate("4a", 20)
    @locker "0x" <> String.duplicate("5a", 20)

    setup do
      ChainHelpers.deploy!(@fleet, %{manager_address: @contract, treasury_address: @treasury})
      ChainHelpers.seed_cursor!(@fleet)
      :ok
    end

    test "until the fleet has voted for a launch there is nothing to look after", %{conn: conn} do
      ChainViews.put!(launch_views(0, :active, 1))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert text(view, "#fleet-launch-action-line") == "No launch yet."
      refute has_element?(view, "#fleet-launch [data-onchain-step]")
    end

    # The launch a carried-out proposal made is found from its transaction's
    # receipt. Once its sale has ended anyone may settle it; the rest wait
    # for the sale to be settled.
    test "a launch the fleet voted for can be settled once its sale has ended", %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      [launch_call] = Actions.encode({:launch, launch()}, fleet)
      {target, value, data} = launch_call
      ProposalHelpers.proposal!(@fleet, 1, calls: [%{target: target, value: value, data: data}])
      execution = ProposalHelpers.execution!(@fleet, 1, @stranger)

      TestChainNode.land(execution.transaction_hash, %{}, %{
        "status" => "0x1",
        "logs" => [launched(7)]
      })

      # The sale ends at block 900, and the latest block is 1,000.
      ChainViews.put!(launch_views(0, :active, 900))

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner, "#fleet-launch-action")

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "fleet-launch-action",
        review: %{steps: [settle, bind, release, collect]}
      })

      assert {settle.to, settle.data} == {@strategy, Call.encode("migrate(address)", [@auction])}
      assert {bind.to, bind.data} == {@treasury, Call.encode("bindLaunchToken(uint256)", [7])}
      assert {release.to, release.data} == {@escrow, Call.encode("release()", [])}
      assert {collect.to, collect.data} == {@locker, Call.encode("collect(uint256)", [42])}

      assert has_element?(view, "#fleet-launch-settle:not([disabled])", "Settle sale")

      for button <- ["bind", "release", "collect"] do
        assert has_element?(view, "#fleet-launch-#{button}[disabled]")
        assert text(view, "#fleet-launch-#{button}-why") == "Not settled yet"
      end

      # While the sale is still running, settling it is certain to fail too.
      ChainViews.put!(launch_views(0, :active, 1_500))
      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert text(view, "#fleet-launch-settle-why") == "Sale still running"
    end

    test "once the sale is settled and added to the split, release and collect stay open", %{
      conn: conn
    } do
      ChainViews.put!(launch_views(7, :graduated, 900))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert text(view, "#fleet-launch-settle-why") == "Already settled"
      assert text(view, "#fleet-launch-bind-why") == "Already added"
      assert has_element?(view, "#fleet-launch-release:not([disabled])", "Release tokens")
      assert has_element?(view, "#fleet-launch-collect:not([disabled])", "Collect fees")
      refute has_element?(view, "#fleet-launch-facts")

      # A visitor reads where the launch stands, with no buttons.
      {:ok, view, _html} = live(build_conn(), @path)
      render_async(view)

      assert text(view, "#fleet-launch-sale") == "Sold"
      assert text(view, "#fleet-launch-split") == "Included"
      refute has_element?(view, "#fleet-launch [data-onchain-step]")
    end

    test "a sale that didn't sell says so beside each button that needs one", %{conn: conn} do
      ChainViews.put!(launch_views(7, :failed, 900))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert text(view, "#fleet-launch-settle-why") == "Already settled"

      for button <- ["release", "collect"],
          do: assert(text(view, "#fleet-launch-#{button}-why") == "The sale didn’t sell")
    end
  end

  describe "what's happening" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      Rooms.bootstrap_rooms!(Fleets.catalog_ids())
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

      other = "fleet_tech_classic"
      send(view.pid, {:proposals_changed, other})
      send(view.pid, {:graph_head, other, "log", 9})
      send(view.pid, {:keys_changed, other, [7]})
      Process.sleep(2_200)
      refute has_element?(view, ~s(#fleet-now-list li[data-kind="post"]))
    end

    test "a wait begun in one fleet reads nothing once the page shows another", %{conn: conn} do
      other = "fleet_tech_classic"
      ChainHelpers.deploy!(other)
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

    test "a proposal carried out shows, linked to the proposal", %{conn: conn} do
      ProposalHelpers.proposal!(@fleet, 1)
      ProposalHelpers.execution!(@fleet, 1, @owner)

      {:ok, view, _html} = live(conn, @path)

      line = ~s(#fleet-now-list li[data-kind="executed"])
      assert has_element?(view, ~s(#{line} a[data-proposal="1"]))
      assert text(view, "#{line} .activity-line__text") =~ "Proposal 1 was carried out."
    end

    test "a goal shows by its title to anyone, other items by their titles to Key holders only",
         %{conn: holder} do
      Workspace.open_log(@fleet)
      goal = goal!("Survey the hull")
      task = task!("Map every plate", %{})
      Workspace.link(@fleet, task, goal, "supports")

      # The workspace's changes are older than the keys the setup issued.
      {:ok, view, _html} = live(build_conn(), @path)
      view |> element("#fleet-now-earlier") |> render_click()
      html = render(view)
      lines = text(view, "#fleet-now-list")

      assert lines =~ "set a goal: “Survey the hull”."
      assert lines =~ "added a task."
      assert lines =~ "backed “Survey the hull” with a task."
      refute html =~ "Map every plate"
      refute has_element?(view, ~s(#fleet-now-list a[data-item-link="#{task}"]))

      {:ok, view, _html} = live(holder, @path)
      view |> element("#fleet-now-earlier") |> render_click()
      lines = text(view, "#fleet-now-list")

      assert lines =~ "added a task: “Map every plate”."
      assert lines =~ "backed “Survey the hull” with “Map every plate”."
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

  # What a fleet shows anyone of what its agents are trying: read here by a
  # visitor who is not signed in.
  describe "trying now" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      Workspace.open_log(@fleet)
      %{conn: build_conn()}
    end

    test "an open goal shows by its title, with how much work is open and never the work",
         %{conn: conn} do
      goal = goal!("Sell the first audit")
      task!("Draft the price", %{"progress" => "doing", "assignee_key" => 12})
      task!("Find a buyer", %{"progress" => "doing"})
      task!("Write the offer", %{})

      {:ok, view, html} = live(conn, @path)

      row = ~s(#fleet-trying li[data-goal="#{goal}"])
      assert has_element?(view, ~s(#{row} a[data-item-link="#{goal}"][href="#{item_path(goal)}"]))

      assert text(view, "#fleet-trying-counts") ==
               "1 open goal · 2 tasks in progress · 1 taken · 1 not taken yet"

      refute html =~ "Draft the price"
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

    test "what members wrote shows as text, with nothing that can't be seen", %{conn: conn} do
      written = "<b>Hull</b> <script>alert(1)</script>\u0007\u202Esurvey\u2066 done"

      goal = goal!(written, %{"open_questions" => [written]})

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#fleet-trying-question")
      refute has_element?(view, "#fleet-trying b")
      refute has_element?(view, "#fleet-trying script")
      assert text(view, ~s(#fleet-trying a[data-item-link="#{goal}"])) =~ "<b>Hull</b>"

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

  defp item_path(id), do: WorkspacePage.item_path(@fleet, id)

  defp deploy!(fleet_id \\ @fleet, deployed_block \\ 1),
    do:
      ChainHelpers.deploy!(fleet_id, %{manager_address: @contract, deployed_block: deployed_block})

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

  defp agent_profile! do
    agent = %Actors.Agent{
      wallet_address: @agent,
      chain_id: 8_453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)
  end

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  # The test's agent holding a shard of Cascade's key `token_id`.
  defp shard!(token_id) do
    agent_profile!()
    ChainHelpers.issue_shard!(@fleet, token_id, @agent)
  end

  # One pass of the chain reader over Cascade up to block `head`.
  defp scan!(head, logs) do
    StubClient.put_chain(chain_head(head), logs)
    assert Scanner.step(Fleets.get_fleet!(@fleet), StubClient) == :ok
  end

  # The shards contract issuing the test's agent a 30-day shard of key
  # `token_id` under its first owner, or the wallet named ending it.
  defp shard_log(:issued, token_id, block) do
    expires = DateTime.to_unix(DateTime.utc_now()) + 30 * 86_400

    topics = [
      @shard_issued,
      word(ChainHelpers.onchain_id(@fleet, token_id)),
      address_word(@agent)
    ]

    shards_log(topics, "0x" <> bare_word(expires) <> bare_word(1), block)
  end

  defp shard_log({:ended, by}, token_id, block) do
    topics = [
      @shard_ended,
      word(ChainHelpers.onchain_id(@fleet, token_id)),
      address_word(@agent),
      address_word(by)
    ]

    shards_log(topics, "0x", block)
  end

  defp shards_log(topics, data, block) do
    %{
      "address" => Fleets.get_fleet!(@fleet).shards_address,
      "topics" => topics,
      "data" => data,
      "blockNumber" => "0x" <> Integer.to_string(block, 16),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => word(block),
      "logIndex" => "0x0"
    }
  end

  defp address_word("0x" <> address), do: "0x" <> String.duplicate("0", 24) <> address
  defp bare_word(value), do: value |> word() |> String.slice(2..-1//1)

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

  # What the fleet page's buttons read for the owner: its USDC allowance to
  # the fleet, and the launch the treasury has bound (0 for none), as its
  # factory recorded it and its strategy says it stands at the latest block.
  defp launch_views(bound_id, lifecycle, migration_block) do
    fleet = Fleets.get_fleet!(@fleet)
    lifecycle = Enum.find_index([:none, :active, :graduated, :failed], &(&1 == lifecycle))

    [
      {@usdc, "allowance(address,address)", [@owner, @contract], {"uint256", [0]}},
      {fleet.treasury_address, "launchId()", [], {"uint256", [bound_id]}},
      {@factory, "launches(uint256)", [7],
       {"address,address,address,address,address",
        [@treasury, @launched_token, @auction, @escrow, @treasury]}},
      {@factory, "strategy()", [], {"address", [@strategy]}},
      {@strategy, "lpLocker()", [], {"address", [@locker]}},
      {@strategy, "distribution(address)", [@auction],
       {"uint8,uint64,uint64,uint64,uint64,uint128,uint128,uint128,uint160,uint256," <>
          "address,address,address,address,address,bytes32,uint256",
        [lifecycle, 1, 2, 3, migration_block, 0, 0, 0, 0, 0] ++
          List.duplicate(@locker, 5) ++ ["0x" <> String.duplicate("0", 64), 42]}}
    ]
  end

  defp launch,
    do: %{
      name: "Fleet Coin",
      symbol: "FLT",
      description: "The fleet's own token",
      website: "https://example.com",
      image: "https://example.com/coin.png"
    }

  # The factory's record of launch `id`, made by and for the treasury.
  defp launched(id) do
    topic =
      RegentChain.Event.topic0(
        "LaunchCreated(uint256,address,address,address,address,address,uint64,uint64)"
      )

    %{
      "address" => @factory,
      "topics" => [topic, word(id), address_word(@treasury), address_word(@launched_token)],
      "data" =>
        "0x" <>
          Enum.map_join([@auction, @escrow, @treasury], &String.slice(address_word(&1), 2..-1//1)) <>
          String.duplicate("0", 64) <> String.duplicate("0", 64)
    }
  end

  defp chain_head(number),
    do: %{
      number: number,
      hash: "0x" <> String.duplicate("f", 64),
      timestamp: DateTime.utc_now(),
      base_fee: 0
    }

  # The Key collection moving Accelerant's Key `token_id` to `owner`.
  defp ownership_log(token_id, epoch, "0x" <> owner, block) do
    %{
      "address" => Fleets.get_fleet!("fleet_tech_accelerant").keys_address,
      "topics" => [
        OwnershipLog.topic(),
        word(ChainHelpers.onchain_id("fleet_tech_accelerant", token_id)),
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

  # Privy's active wallet, as the wallet hook of the group `panel` reports it.
  defp active!(view, wallet, panel \\ "#buy-key-order") do
    view
    |> with_target(panel)
    |> render_hook("onchain_active_wallet", %{"address" => wallet})

    render_async(view)
  end

  # The chain the buy steps read: sales open, and the wallet's USDC
  # allowance to the fleet.
  defp chain!(opts) do
    allowance = Call.selector("allowance(address,address)")
    sales_open = Call.selector("salesOpen(uint256)")

    StubClient.put_chain(chain_head(1_000), [],
      calls: fn _to, data, _hash -> answer(data, allowance, sales_open, opts) end
    )
  end

  defp answer(data, allowance, sales_open, opts) do
    cond do
      String.starts_with?(data, allowance) -> {:ok, <<Keyword.fetch!(opts, :allowance)::256>>}
      String.starts_with?(data, sales_open) -> {:ok, <<1::256>>}
      true -> {:error, :no_answer}
    end
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

  test "agents that couldn't be counted are said to be so, never shown as none" do
    html =
      render_component(&KeyfleetWeb.FleetLive.headcount/1,
        id: "fleet-sales",
        sales: %{deployed?: false},
        agents: nil
      )

    assert html =~ "Couldn't count the agents here just now"
    refute html =~ "agents here</"

    html =
      render_component(&KeyfleetWeb.CheckIns.who_is_here/1,
        agents: [],
        agents_here: nil,
        on_close: %Phoenix.LiveView.JS{}
      )

    assert html =~ "No agents here yet."
    refute html =~ "agents are here. These are"
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
