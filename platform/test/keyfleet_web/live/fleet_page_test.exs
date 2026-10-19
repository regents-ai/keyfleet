defmodule KeyfleetWeb.Live.FleetPageTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors
  alias Keyfleet.Agents.Here
  alias Keyfleet.Chain.{OwnershipLog, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals.Actions
  alias Keyfleet.Rooms
  alias Keyfleet.SharedReading
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.FleetNow
  alias KeyfleetWeb.FleetProposals
  alias KeyfleetWeb.WorkspacePage
  alias Phoenix.Socket.Broadcast
  alias RegentChain.Call

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/cascade/1"
  @map_path @path <> "?view=map"
  @members_path @path <> "?view=members"
  @treasury_path @path <> "/treasury"
  @issued 150
  @owner "0x" <> String.duplicate("a", 40)
  @stranger "0x" <> String.duplicate("b", 40)
  @contract "0x" <> String.duplicate("7", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()
    ChainHelpers.open_cursor!(@fleet)

    for token_id <- 1..@issued, do: issue!(@fleet, token_id)
    # A chain that answers no reads until a test says what it holds.
    StubClient.put_chain(chain_head(1_000), [])
    # No fleet's reading is left from another test: a hall shown to anyone
    # but a member draws from the reading the test takes (`read_now/1`).
    Enum.each(Fleets.catalog_ids(), &SharedReading.delete(FleetNow.key(&1)))

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

  # However many Keys an address holds, the Member List shows it once, with
  # how many it holds and its lowest fifty as cards; the bar counts them all.
  test "the Member List shows each holder once with the Keys it holds", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)
    Here.read(@fleet)
    move!(7, @stranger)

    {:ok, view, _html} = live(conn, @members_path)

    assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"
    assert holders(view) == [@owner, @stranger]
    assert text(view, "#fleet-members-holder-#{@owner} .member-card__count") == "149 Keys"
    assert shown_keys(view, @owner) == Enum.to_list(1..6) ++ Enum.to_list(8..51)
    assert text(view, "#fleet-members-holder-#{@owner} .fleet-entry__more") == "and 99 more"
    assert shown_keys(view, @stranger) == [7]
    refute has_element?(view, "#fleet-members-next")
    refute has_element?(view, "#fleet-members-previous")
  end

  # Every address a person's account links is counted as one card under their
  # main address; an address no account links keeps a card of its own.
  test "the Member List shows each person once with the Keys of all their addresses", %{
    conn: conn
  } do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)
    [main, first, second, loose] = for _ <- 1..4, do: unclaimed_wallet()
    move!(7, first)
    move!(9, second)
    move!(10, second)
    move!(8, loose)

    Accounts.register_verified!(
      "did:privy:member-list",
      String.upcase(main),
      [main, first, String.replace_prefix(String.upcase(second), "0X", "0x")],
      actor: %Keyfleet.Actors.System{}
    )

    {:ok, view, _html} = live(conn, @members_path)

    assert Enum.drop(holders(view), 1) == [main, loose]
    assert text(view, "#fleet-members-holder-#{main} .member-card__count") == "3 Keys"
    assert text(view, "#fleet-members-holder-#{main} strong") == RegentFormat.short_address(main)
    assert shown_keys(view, main) == [7, 9, 10]
    refute render(view) =~ RegentFormat.short_address(first)
    assert shown_keys(view, loose) == [8]
  end

  # A typed name could read like an ENS name, so the short main address sits
  # under it; an ENS name read from the chain stands alone.
  test "the Member List shows a typed name over its address and an ENS name alone", %{
    conn: conn
  } do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)
    [typed, ens] = for _ <- 1..2, do: unclaimed_wallet()
    move!(7, typed)
    move!(8, ens)

    Accounts.register_verified!("did:privy:typed-name", typed, [typed],
      actor: %Keyfleet.Actors.System{}
    )

    ens_account =
      Accounts.register_verified!("did:privy:ens-name", ens, [ens],
        actor: %Keyfleet.Actors.System{}
      )

    Keyfleet.Repo.query!(
      "INSERT INTO regent_identity.profiles (id, app_id, privy_user_id, display_name, " <>
        "proof_issued_at, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), 'keyfleet-test', 'did:privy:typed-name', 'vitalik.eth', 0, now(), now())"
    )

    Keyfleet.Repo.query!(
      "INSERT INTO keyfleet_app.account_ens_identities (id, human_account_id, wallet_address, " <>
        "ens_name, lookup_state, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $2, 'crew.eth', 'done', now(), now())",
      [ens_account.id, ens]
    )

    {:ok, view, _html} = live(conn, @members_path)

    assert text(view, "#fleet-members-holder-#{typed} strong") == "vitalik.eth"

    assert text(view, "#fleet-members-holder-#{typed} strong + span") ==
             RegentFormat.short_address(typed)

    assert text(view, "#fleet-members-holder-#{ens} strong") == "crew.eth"

    refute has_element?(
             view,
             "#fleet-members-holder-#{ens} strong + span:not(.member-card__count)"
           )
  end

  test "a visitor is listed General alone, never another room's name", %{conn: conn} do
    deploy!()
    Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic = 'Hull survey', topic_set_by = $1, " <>
        "topic_set_at = now() WHERE fleet_id = $2 AND slug = 'open-1'",
      [@owner, @fleet]
    )

    read_now()
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(#fleet-channels a[href="#{@path}/rooms/general"]), "General")
    refute has_element?(view, ~s(#fleet-channels a[href="#{@path}/rooms/open-1"]))
    refute has_element?(view, ~s(#fleet-channels a[href="#{@path}/rooms/open-2"]))
    refute render(view) =~ "Hull survey"
  end

  # An open fleet's rooms are opened by the deploy that opens it; until then
  # the hall's channels say it has none.
  test "a fleet with no rooms yet says so among its channels", %{conn: conn} do
    ChainHelpers.deploy!("fleet_tech_classic")
    read_now("fleet_tech_classic")
    {:ok, view, _html} = live(conn, "/classic/1")

    assert text(view, "#fleet-channels .fleet-channels__empty") == "No rooms yet."
    refute has_element?(view, ~s(#fleet-channels a[href*="/rooms/"]))
  end

  test "the bar's one row of tabs leads to the hall, the Keys and the treasury", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, _html} = live(conn, @path)

    assert text(view, ".fleet-bar__nav") == "Chat Treasury Proposals Workspace Keys"
    assert has_element?(view, ~s(#fleet-tab-hall[href="#{@path}"][aria-current="page"]), "Chat")
    assert has_element?(view, ~s(#fleet-tab-workspace[href="#{@path}/workspace"]), "Workspace")

    assert has_element?(
             view,
             ~s{#fleet-tab-keys[href="#{@map_path}"]:not([aria-current])},
             "Keys"
           )

    assert has_element?(view, ~s(#fleet-tab-treasury[href="#{@treasury_path}"]), "Treasury")
    assert has_element?(view, "#fleet-hall")
    refute has_element?(view, "#fleet-members")
    # The hall's sidebar leaves the tabs to the bar.
    refute has_element?(view, ~s(#fleet-channels a[href="#{@path}/workspace"]))
    refute has_element?(view, ~s(#fleet-channels a[href="#{@path}/proposals"]))

    view |> element("#fleet-tab-keys") |> render_click()
    assert_patch(view, @map_path)

    assert has_element?(view, ~s(#fleet-tab-keys[aria-current="page"]))
    assert has_element?(view, ~s(#fleet-keys-map-grid[aria-current="page"]), "Grid")
    assert has_element?(view, "#key-map-#{@fleet}")
    refute has_element?(view, "#fleet-hall")
    refute has_element?(view, "#fleet-members")

    view |> element("#fleet-keys-map-list") |> render_click()
    assert_patch(view, @members_path)

    assert has_element?(view, ~s(#fleet-tab-keys[aria-current="page"]))
    assert has_element?(view, ~s(#fleet-keys-members-list[aria-current="page"]), "List")
    assert has_element?(view, "#fleet-members h2", "Member List")
    refute has_element?(view, "#key-map-#{@fleet}")
    refute has_element?(view, "#fleet-hall")

    view |> element("#fleet-keys-members-grid") |> render_click()
    assert_patch(view, @map_path)

    # The Treasury page draws on the reading every visitor shares, whose
    # producer doesn't run under test (`KeyfleetWeb.FleetProposals`).
    FleetProposals.read(@fleet)

    # How the fleet works and how it decides are on its Treasury page, not
    # beside the buttons that buy a Key.
    refute has_element?(view, "#fleet-about .fleet-risks")

    view |> element("#fleet-tab-treasury") |> render_click()
    assert_patch(view, @treasury_path)

    assert text(view, "#treasury-rules") =~
             "When a level sells out, the holders of the level before it are paid back"

    assert has_element?(view, "#treasury-rules #treasury-risks summary", "How a fleet decides")

    for row <- Keyfleet.Authority.treasury_rows() do
      assert has_element?(view, "#treasury-rules dt", row.what)
      assert has_element?(view, "#treasury-rules dd", row.who)

      assert has_element?(
               view,
               "#treasury-rules dd .proposals-detail",
               Keyfleet.Authority.needs(row)
             )
    end

    assert has_element?(
             view,
             ~s(#treasury-rules a#fleet-contract-link[href="https://basescan.org/address/#{@contract}"])
           )

    assert has_element?(view, ~s(#treasury-rules code[title="#{@contract}"]))
  end

  test "a Member List page that is not one of its pages is a page that doesn't exist", %{
    conn: conn
  } do
    deploy!()

    for page <- ["nonsense", "0", "2"] do
      assert_raise KeyfleetWeb.NotFoundError, fn ->
        live(conn, @members_path <> "&page=" <> page)
      end
    end
  end

  # A fleet with no contract has sold nothing: it shows what it will sell, and
  # no sales figures.
  test "a fleet not yet deployed shows what it will sell and no sales figures", %{conn: conn} do
    ChainHelpers.seed_cursor!("fleet_tech_classic")

    {:ok, view, html} = live(conn, "/classic/1")

    assert html =~ "Sales open soon"
    assert text(view, "#fleet-soon-facts") =~ "1,024"
    assert text(view, "#fleet-soon-facts") =~ "10–100 USDC"
    refute has_element?(view, "#fleet-sales")
    refute has_element?(view, "#fleet-get-key")

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
    Here.read(@fleet)

    {:ok, view, _html} = live(conn, @members_path)

    assert text(view, "#fleet-sales") == "Figures are catching up · 0 agents here"
    assert holders(view) == [@owner]

    FleetProposals.read(@fleet)
    {:ok, treasury, html} = live(conn, @treasury_path)

    assert text(treasury, "#fleet-progress-title + p") == "Figures are catching up."
    refute html =~ "Keys issued"
  end

  describe "a fleet coming soon" do
    # Keys issued and rooms opened make no difference: until its deployment
    # is recorded, the page offers nothing to buy and nothing to join.
    test "shows its name and that it opens later, and nothing to buy or join", %{conn: conn} do
      Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, html} = live(conn, @path)

      assert has_element?(view, "#fleet-soon h1", "Cascade #1")
      assert has_element?(view, "#fleet-soon-title", "Sales open soon")
      assert has_element?(view, ~s(#fleet-soon a[href="/"]), "See the fleets")
      # Cascade has no supply limit, so only its first price shows.
      assert text(view, "#fleet-soon-facts") =~ "From 10 USDC"
      refute text(view, "#fleet-soon-facts") =~ "Keys"

      for id <-
            ~w(fleet-get-key fleet-send-agent fleet-channels fleet-members fleet-tab-workspace
                   fleet-tab-proposals fleet-tab-treasury fleet-tab-keys fleet-feed-list fleet-entry) do
        refute has_element?(view, "##{id}")
      end

      refute html =~ "Keys sold"
    end

    test "its rooms, workspace, proposals and treasury lead back to its page", %{conn: conn} do
      Keyfleet.Rooms.bootstrap_rooms!(Fleets.catalog_ids())

      {:ok, view, _html} = live(conn, @path)

      for page <-
            ~w(/rooms/general /workspace /workspace/task%231 /proposals /proposals/1 /treasury) do
        assert {:error, {:live_redirect, %{to: @path}}} = live(conn, @path <> page)

        # Reached from inside the shell, the same page patches back.
        render_patch(view, @path <> page)
        assert_patch(view, @path)
        assert has_element?(view, "#fleet-soon-title", "Sales open soon")
      end
    end

    test "opens once its deployment is recorded", %{conn: conn} do
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#fleet-soon-title", "Sales open soon")

      deploy!()
      Here.read(@fleet)

      {:ok, view, _html} = live(conn, @path)
      assert text(view, "#fleet-sales") == "150 Keys sold · 0 agents here"
      assert text(view, "#fleet-entry .fleet-entry__line") == "You hold 150 Keys."
      refute has_element?(view, "#fleet-soon")
    end
  end

  describe "buying the next key" do
    # Key 151 opens level 9, whose price is the first to round up. The offer
    # heads the panel in one line, with Buy straight under it.
    test "offers the next key's number, exact price and level", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 45_150_000)

      {:ok, view, _html} = live(conn, @path)
      render_async(view, 3_000)

      assert text(view, "#fleet-about #buy-key-title #buy-key-offer") ==
               "Key 151 · 42.99817 USDC · Level 9"

      assert text(view, "#buy-key-tip") =~ "costs no more than 45.15 USDC"
      assert text(view, "#buy-key-number") == "151"
      assert text(view, "#buy-key-price") == "42.99817 USDC"
      assert text(view, "#fleet-about #buy-key-order #buy-key-button") == "Buy Key 151"
      refute has_element?(view, "#buy-key-button-why")
    end

    # The steps are built on the server for the wallet that sends them, and
    # the page has them before anyone presses: an approval of the most the
    # purchase may cost when the wallet hasn't allowed that much, then the purchase.
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
      assert approve.data == Call.encode("approve(address,uint256)", [@contract, 45_150_000])
      assert buy.to == @contract
      assert "0x" <> _calldata = buy.data

      assert text(view, "#buy-key-order-line") ==
               "Key 151: 42.99817 USDC. If it sells first, you get the next Key for up to 45.15 USDC."

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
      chain!(allowance: 45_150_000)
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

      render_async(view, 3_000)

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

      assert text(view, "#buy-key-order-line") ==
               "Key 151: 42.99817 USDC. If it sells first, you get the next Key for up to 45.15 USDC."
    end

    test "a purchase that doesn't go through says why it may not have", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      chain!(allowance: 45_150_000)

      {:ok, view, _html} = live(conn, @path)
      active!(view, @owner)
      assert_push_event(view, "onchain-steps:review", %{review: %{steps: [buy]} = review})

      hash = "0x" <> String.duplicate("2", 64)
      chain!(allowance: 45_150_000)
      TestChainNode.land!(hash, review, buy, "0x0")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "buy",
        "transaction_hash" => hash
      })

      render_async(view, 3_000)
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

      assert text(view, "#buy-key-order-line") ==
               "Key 151: 42.99817 USDC. If it sells first, you get the next Key for up to 45.15 USDC."

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

      read_now()
      {:ok, view, _html} = live(init_test_session(build_conn(), %{}), @path)
      active!(view, @owner)

      refute_push_event(view, "onchain-steps:review", %{review: %{}})

      assert text(view, "#buy-key-order-line") ==
               "Key 151: 42.99817 USDC. If it sells first, you get the next Key for up to 45.15 USDC."

      refute has_element?(view, "#buy-key-button[disabled]")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_failed", %{"step" => "buy", "reason" => "wallet_unavailable"})

      assert text(view, "#buy-key-order-press-note") == "Sign in to send this. Nothing was sent."
    end

    test "a fleet without levels offers its key with no level", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      read_now("fleet_tech_classic")
      chain!(allowance: 10_500_000, minted: 0, price: 10_000_000)

      {:ok, view, _html} = live(conn, "/classic/1")
      render_async(view, 3_000)

      assert text(view, "#buy-key-number") == "1"
      assert text(view, "#buy-key-price") == "10 USDC"
      refute has_element?(view, "#buy-key-level")
    end

    # A purchase from a fleet the chain says is sold out is certain to fail,
    # so Buy stays in view but can't be pressed, and the words beside it say why.
    test "a sold-out fleet keeps Buy in view, not pressable, with Sold out beside it",
         %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..1_024, do: issue!("fleet_tech_classic", token_id)
      chain!(allowance: 0, minted: 1_024, price: :sold_out)

      {:ok, view, _html} = live(conn, "/classic/1")
      active!(view, @owner)

      assert text(view, "#buy-key-button-why") == "Sold out"
      assert text(view, "#buy-key-elsewhere") =~ "You can still get a Key from someone"
      assert has_element?(view, "#buy-key-offer[hidden]")
      assert has_element?(view, "#buy-key-approve[hidden]")
      assert has_element?(view, "#buy-key-button")

      assert has_element?(
               view,
               "#buy-key-button[disabled][aria-describedby=buy-key-button-why]",
               "Buy Key"
             )

      refute has_element?(view, "#fleet-get-key")
    end

    test "a fleet with keys left has no sold-out line and Buy can be pressed", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      read_now("fleet_tech_classic")
      chain!(allowance: 10_500_000, minted: 0, price: 10_000_000)

      {:ok, view, _html} = live(conn, "/classic/1")
      render_async(view, 3_000)

      refute has_element?(view, "#buy-key-button-why")
      refute has_element?(view, "#buy-key-elsewhere")
      refute has_element?(view, "#buy-key-button[disabled]")
    end

    # The buyer's purchases and how each landed stay when the last key sells
    # while the page is open.
    test "a fleet that sells out while open keeps the buyer's purchases", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      for token_id <- 1..1_023, do: issue!("fleet_tech_classic", token_id)
      chain!(allowance: 105_000_000, minted: 1_023, price: 100_000_000)
      {:ok, view, _html} = live(conn, "/classic/1")
      render_async(view, 3_000)
      assert text(view, "#buy-key-number") == "1,024"
      assert text(view, "#buy-key-price") == "100 USDC"

      active!(view, @owner)
      assert_push_event(view, "onchain-steps:review", %{review: %{steps: [buy]} = review})
      hash = "0x" <> String.duplicate("3", 64)
      chain!(allowance: 105_000_000, minted: 1_024, price: :sold_out)
      TestChainNode.land!(hash, review, buy, "0x1")

      view
      |> with_target("#buy-key-order")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "buy",
        "transaction_hash" => hash
      })

      render_async(view, 3_000)

      issue!("fleet_tech_classic", 1_024, @owner)
      send(view.pid, {:keys_changed, "fleet_tech_classic", [1_024]})

      assert text(view, "#buy-key-button-why") == "Sold out"
      assert has_element?(view, "#buy-key-button[disabled]")
      assert has_element?(view, "#buy-key-order-sent li[data-state=confirmed] strong", "Buy Key")
      assert text(view, "#buy-key-order-sent span") =~ "Done. The Key is yours"
    end

    test "a fleet not yet deployed offers nothing to buy", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#buy-key")
    end

    # "Buy Key" opens "Get a Key" and takes the reader to buying a key.
    test "Buy Key opens Get a Key at Buying a key" do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      read_now()

      {:ok, view, _html} = live(build_conn(), @path)
      commands = click_commands(view, "#fleet-get-key")

      assert ["remove_attr", %{"attr" => "hidden", "to" => "#fleet-about"}] in commands

      assert ["set_attr", %{"attr" => ["aria-expanded", "true"], "to" => "#fleet-get-key"}] in commands
      assert ["focus", %{"to" => "#buy-key-title"}] in commands
      assert has_element?(view, ~s(#fleet-about #buy-key #buy-key-title[tabindex="-1"]))
    end

    # A buyer sees what the next Key costs before pressing anything, as the
    # Buy button will name it: on the fleet's own button, with no line beside
    # it, and on the homepage's "Buy Next Key".
    test "the next Key and its price show before any press" do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      read_now("fleet_tech_classic")

      {:ok, view, _html} = live(build_conn(), "/classic/1")

      assert text(view, "#fleet-entry #fleet-get-key") ==
               "Join this Keyfleet by purchasing the next Key: 10 USDC"

      refute has_element?(view, "#fleet-entry .fleet-entry__line")

      {:ok, home, _html} = live(build_conn(), "/")
      render_async(home, 3_000)

      assert has_element?(home, "button#home-buy-next-key", "Key 1 · 10 USDC")
    end

    # The header's "Get a Key", there for everyone on every app page, lands on
    # Classic with its own "Get a Key" pressed, then drops the press from the
    # address so the next press opens it again.
    test "the header's Get a Key lands on Classic at Buying a Key", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      read_now("fleet_tech_classic")

      {:ok, view, _html} = live(conn, @path)
      view |> element("#shell-get-key") |> render_click()
      assert_patch(view, "/classic/1?buy")

      # Drawn already open as "Get a Key", so it shows before the page connects.
      assert has_element?(view, "#fleet-about:not([hidden])")

      [arrival] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#fleet-get-key-on-arrival")
        |> LazyHTML.attribute("phx-mounted")

      assert Jason.decode!(arrival) ==
               click_commands(view, "#fleet-get-key") ++
                 [["patch", %{"href" => "/classic/1", "replace" => true}]]
    end
  end

  describe "the key map" do
    # Each fleet draws its keys in its own shape, and only once it is deployed.
    test "every fleet's map draws its own layout", %{conn: conn} do
      {:ok, view, _html} = live(conn, @map_path)
      refute has_element?(view, "#fleet-map")

      for {fleet_id, layout} <- [
            {"fibonacci_syndicate", "fibonacci"},
            {"fibonacci_cascade", "fibonacci"},
            {"fleet_tech_classic", "classic"},
            {"fleet_tech_accelerant", "accelerant"}
          ] do
        deploy!(fleet_id)
        ChainHelpers.seed_cursor!(fleet_id)
        {:ok, view, _html} = live(conn, "#{Keyfleet.Fleets.path(fleet_id)}?view=map")

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
      {:ok, view, _html} = live(conn, @map_path)

      assert has_element?(view, "#key-map-next", "Next Key")
      assert has_element?(view, "#key-map-mine", "Your Keys")

      assert option_values(view, "#key-map-level-choice option") ==
               Enum.map(1..9, &to_string/1)

      {:ok, view, _html} = live(build_conn(), @map_path)
      refute has_element?(view, "#key-map-mine")

      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      {:ok, view, _html} = live(conn, "/classic/1?view=map")
      refute has_element?(view, "#key-map-level")
    end

    test "someone signed out holds none of the keys, and can search the map", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      assert {:ok, _view, _html} = live(conn, @map_path)

      {:ok, view, _html} = live(build_conn(), @map_path)
      render_hook(view, "keymap_ready", %{})

      assert_reply(view, %{mine: mine})
      assert Base.decode64!(mine) == ""

      # The map asks for the card close-ups of the Keys in view; none is made
      # here, so every Key keeps its number.
      render_hook(view, "keymap_pictures", %{"keys" => [1, 2, 152]})
      assert_reply(view, %{pictures: []})

      # Anyone can search the map: a number finds that Key, an address every
      # Key it holds here, in either case of letters.
      assert has_element?(view, ~s(#key-map-find input[name="q"]))
      assert has_element?(view, ~s(output#key-map-found[form="key-map-find"]))
      all = KeyfleetWeb.KeyMap.bitset(1..@issued)

      for {sought, keys, words} <- [
            {" 12 ", KeyfleetWeb.KeyMap.bitset([12]), "Key 12."},
            {"151", KeyfleetWeb.KeyMap.bitset([151]), "Key 151."},
            {"152", "", "No Key 152 yet."},
            {@owner, all, "0xaaaa..aaaa holds 150 Keys here."},
            {String.upcase(@owner) |> String.replace_prefix("0X", "0x"), all,
             "0xaaaa..aaaa holds 150 Keys here."},
            {"0x" <> String.duplicate("b", 40), "", "0xbbbb..bbbb holds no Keys here."},
            {"twelve", "", "Enter a Key number or a 0x address."},
            {"0xaaaa", "", "Enter a Key number or a 0x address."},
            {"", "", ""}
          ] do
        render_hook(view, "find_keys", %{"q" => sought})
        assert_reply(view, %{keys: ^keys, words: ^words})
      end
    end

    # Every key sold and the next one can be chosen; the choice goes into the
    # address, and back and forward move through it. The member list's pages
    # keep it.
    test "a key chosen goes into the address, and back and forward follow it", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @map_path)

      render_hook(view, "select_key", %{"token_id" => 151})
      assert_patch(view, @map_path <> "&key=151")
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "Key 151 chosen."
      assert has_element?(view, ~s(#key-map-fibonacci_cascade[data-selected="151"]))

      for refused <- [0, 152, -1, "12", 1.5, nil] do
        render_hook(view, "select_key", %{"token_id" => refused})
        refute_patched(view)
      end

      # Key 12 is sold, so its profile asks the chain what it has waiting.
      StubClient.put_chain(chain_head(1_000), [])
      render_patch(view, @map_path <> "&key=12")
      assert_push_event(view, "keymap:select", %{token_id: 12})
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "Key 12 chosen."

      render_patch(view, @map_path <> "&key=152")
      assert_push_event(view, "keymap:select", %{token_id: nil})
      assert text(view, "#key-map-selected .key-map-selected__chosen") == "No Key chosen yet."
    end

    # A key sold, moved or given a shard reaches an open page as that key's new marks.
    test "a key sold by the chain reader reaches the map as a change", %{conn: conn} do
      fleet = deploy!("fleet_tech_accelerant", 5_000_000)
      Here.read("fleet_tech_accelerant")
      {:ok, view, _html} = live(conn, "/accelerant/1?view=map")

      StubClient.put_chain(chain_head(5_000_010), [
        ownership_log(1, 1, @owner, 5_000_003),
        ownership_log(2, 1, @stranger, 5_000_004)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_pushed(view, "keymap:patch", %{minted: 2, keys: [[1, 1], [2, 0]]})
      assert text(view, "#fleet-sales") == "2 Keys sold · 0 agents here"

      StubClient.put_chain(chain_head(5_000_020), [
        ownership_log(1, 1, @owner, 5_000_003),
        ownership_log(2, 1, @stranger, 5_000_004),
        ownership_log(1, 2, @stranger, 5_000_015)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_pushed(view, "keymap:patch", %{minted: 2, keys: [[1, 0]]})
    end

    test "more than 2,000 keys changed at once tells the map to load again", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @map_path)

      send(view.pid, {:keys_changed, @fleet, Enum.to_list(1..2_000)})
      assert_pushed(view, "keymap:patch", %{keys: keys})
      assert length(keys) == 2_000

      send(view.pid, {:keys_changed, @fleet, Enum.to_list(1..2_001)})
      assert_pushed(view, "keymap:reset", %{})
    end

    test "a change in another fleet leaves the page as it is", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @map_path)
      # The Buy panel's own read of the chain lands first, so it isn't taken
      # for a change.
      render_async(view, 3_000)
      shown = render(view)

      send(view.pid, {:keys_changed, "fibonacci_syndicate", [7, 151]})

      # Rendered first, so the page has handled the change by the time its
      # pushes are checked.
      assert render(view) == shown
      refute_push_event(view, "keymap:patch", _patch, 0)
      refute_push_event(view, "keymap:reset", _reset, 0)
    end

    # Keys changing hands reach an open Member List, and a Key sold joins it.
    test "the Member List shows a Key's new holder once it changes hands", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @members_path)
      assert holders(view) == [@owner]

      move!(7, @stranger)
      send(view.pid, {:keys_changed, @fleet, [7]})
      assert_pushed(view, "keymap:patch", %{keys: [[7, 0]]})
      assert holders(view) == [@owner, @stranger]
      assert shown_keys(view, @stranger) == [7]

      issue!(@fleet, 151, @stranger)
      send(view.pid, {:keys_changed, @fleet, [151]})
      assert_pushed(view, "keymap:patch", %{minted: 151, keys: [[151, 0]]})
      assert shown_keys(view, @stranger) == [7, 151]
    end

    test "a key in the address that isn't one on the map is no choice", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      for key <- ["abc", "-1", "0", "152", "99999999999999999999999", "1.5", ""] do
        {:ok, view, _html} = live(conn, @map_path <> "&" <> URI.encode_query(key: key))

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
    read_now()
    {:ok, view, _html} = live(conn, @path)
    refute has_element?(view, "#fleet-send-agent-dialog")

    view |> element(".fleet-bar #fleet-send-agent") |> render_click()

    instruction = text(view, "#fleet-send-agent-instruction")

    assert instruction ==
             "Install the Keyfleet skill from keyfleet.ai/skill.md and follow it. Then look at the Cascade #1 fleet."

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
      read_now()
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
  # member list and the map move on, the buyer's way in becomes their Key,
  # and the Treasury page counts it.
  test "a key bought appears once the chain reader records it", %{conn: conn} do
    fleet = deploy!("fleet_tech_accelerant", 5_000_000)
    {:ok, view, _html} = live(conn, "/accelerant/1?view=members")
    assert has_element?(view, "#fleet-get-key", "Join this Keyfleet by purchasing the next Key")

    StubClient.put_chain(chain_head(5_000_010), [ownership_log(1, 1, @owner, 5_000_003)])
    assert Scanner.step(fleet, StubClient) == :ok

    assert_pushed(view, "keymap:patch", %{minted: 1, keys: [[1, 1]]})

    assert text(view, "#fleet-entry .fleet-entry__line") == "You hold Key 1."
    refute has_element?(view, "#fleet-get-key")

    assert shown_keys(view, @owner) == [1]

    FleetProposals.read("fleet_tech_accelerant")
    {:ok, treasury, _html} = live(conn, "/accelerant/1/treasury")
    assert text(treasury, "#fleet-progress-title + dl") =~ "Keys issued 1 of 2,000"
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
      FleetProposals.read(@fleet)
      ChainViews.put!(launch_views(0, :active, 1))

      {:ok, view, _html} = live(conn, @treasury_path)
      render_async(view, 3_000)

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
      FleetProposals.read(@fleet)
      ChainViews.put!(launch_views(0, :active, 900))

      {:ok, view, _html} = live(conn, @treasury_path)
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
      {:ok, view, _html} = live(conn, @treasury_path)
      render_async(view, 3_000)
      assert text(view, "#fleet-launch-settle-why") == "Sale still running"
    end

    test "once the sale is settled and added to the split, release and collect stay open", %{
      conn: conn
    } do
      FleetProposals.read(@fleet)
      ChainViews.put!(launch_views(7, :graduated, 900))

      {:ok, view, _html} = live(conn, @treasury_path)
      render_async(view, 3_000)

      assert text(view, "#fleet-launch-settle-why") == "Already settled"
      assert text(view, "#fleet-launch-bind-why") == "Already added"
      assert has_element?(view, "#fleet-launch-release:not([disabled])", "Release tokens")
      assert has_element?(view, "#fleet-launch-collect:not([disabled])", "Collect fees")
      refute has_element?(view, "#fleet-launch-facts")

      # A visitor reads where the launch stands, with no buttons.
      {:ok, view, _html} = live(build_conn(), @treasury_path)
      render_async(view, 3_000)

      assert text(view, "#fleet-launch-sale") == "Sold"
      assert text(view, "#fleet-launch-split") == "Included"
      refute has_element?(view, "#fleet-launch [data-onchain-step]")
    end

    test "a sale that didn't sell says so beside each button that needs one", %{conn: conn} do
      FleetProposals.read(@fleet)
      ChainViews.put!(launch_views(7, :failed, 900))

      {:ok, view, _html} = live(conn, @treasury_path)
      render_async(view, 3_000)

      assert text(view, "#fleet-launch-settle-why") == "Already settled"

      for button <- ["release", "collect"],
          do: assert(text(view, "#fleet-launch-#{button}-why") == "The sale didn’t sell")
    end
  end

  describe "the hall's feed" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      Rooms.bootstrap_rooms!(Fleets.catalog_ids())
      :ok
    end

    test "a post appears once the page reads the fleet again, its words as text", %{conn: conn} do
      writer = PairingHelpers.agent_for!(owner())
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))

      post =
        Rooms.send_message!(
          %{
            fleet_id: @fleet,
            slug: "general",
            body: "<b>Hull</b> <script>alert(1)</script>\u0007\u202Esurvey\u2066 done",
            idempotency_key: Ash.UUID.generate()
          },
          actor: writer
        )

      # The notice of the post came first; the message stands in for the wait.
      send(view.pid, {:refresh_activity, @fleet})

      line = "#fleet-feed-posts-#{post.id}[data-kind=\"post\"]"
      assert has_element?(view, ~s(#{line} a[data-key="1"]))
      assert has_element?(view, ~s(#{line} a[data-room="general"][href="#{@path}/rooms/general"]))
      refute has_element?(view, "#fleet-feed-list b")
      refute has_element?(view, "#fleet-feed-list script")
      assert text(view, line) =~ "<b>Hull</b> <script>alert(1)</script>"

      # No character that can't be seen, or that reverses the text around it.
      html = view |> element("#fleet-feed-list") |> render()
      refute html =~ ~r/[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}-\x{9F}\p{Cf}]/u
    end

    test "a person sends their agent words to quote and sees the room it quoted them in" do
      agent = PairingHelpers.agent_for!(owner())
      conn = init_test_session(build_conn(), %{human_account_id: agent.human_account_id})
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#fleet-quote-sent")

      view |> form("#fleet-quote-form", quote: %{body: "Hull survey done"}) |> render_submit()

      assert text(view, "#fleet-quote-note") == "Sent"
      assert text(view, "#fleet-quote-body") == ""
      assert text(view, "#fleet-quote-sent q") == "Hull survey done"
      assert text(view, "#fleet-quote-sent span") == "Waiting for your agent"

      assert {:ok, %{requests: [request]}} = Rooms.quote_changes(@fleet, 0, agent)

      Rooms.send_message!(
        %{
          fleet_id: @fleet,
          slug: "coding",
          body: request.body,
          idempotency_key: Ash.UUID.generate(),
          quote_request_id: request.id
        },
        actor: agent
      )

      send(view.pid, {:refresh_activity, @fleet})

      assert has_element?(
               view,
               ~s(#fleet-quote-#{request.id} a[href="#{@path}/rooms/coding"]),
               "Quoted in coding"
             )
    end

    test "a person without a paired agent is told how to get one, and nobody signed out sees the box",
         %{conn: conn} do
      read_now()
      {:ok, view, _html} = live(conn, @path)
      assert text(view, "#fleet-quote h2") == "Say something here"
      assert has_element?(view, ~s(#fleet-quote a[href="https://regents.sh"]))
      refute has_element?(view, "#fleet-quote-form")

      {:ok, signed_out, _html} = live(build_conn(), @path)
      refute has_element?(signed_out, "#fleet-quote")
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

    test "a read again that fails keeps the hall as it was, and the next notice reads again",
         %{conn: conn} do
      now = DateTime.utc_now()
      line!("general", 1, now)
      {:ok, view, _html} = live(conn, @path)
      before = now_items(view)

      rename!("messages", "messages_away")

      log =
        capture_log(fn ->
          send(view.pid, {:proposals_changed, @fleet})
          Process.sleep(2_200)
          render(view)
        end)

      assert now_items(view) == before
      assert log =~ "Reading the fleet page failed"

      rename!("messages_away", "messages")
      line!("coding", 0, now)
      send(view.pid, {:proposals_changed, @fleet})
      Process.sleep(2_200)

      assert [_new | ^before] = now_items(view)
    end

    test "Show earlier that can't be read keeps the hall and says what to do", %{conn: conn} do
      now = DateTime.utc_now()
      for n <- 1..200, do: line!(if(rem(n, 2) == 0, do: "general", else: "coding"), n, now)
      {:ok, view, _html} = live(conn, @path)
      first = now_items(view)

      rename!("messages", "messages_away")
      log = capture_log(fn -> view |> element("#fleet-feed-earlier") |> render_click() end)

      assert now_items(view) == first
      assert render(view) =~ "Something went wrong on our side."
      assert log =~ "Reading the app page failed"
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
      refute has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))
    end

    # Anyone but a member sees the hall as everyone does, so a crowd of them
    # costs what one visitor costs: the fleet is read once for all of them
    # (`KeyfleetWeb.FleetNow`), and each open hall draws that reading.
    test "a visitor's open hall reads nothing on the fleet's notices, and draws its next reading" do
      # Written two hours back: before the Keys were sold, so it is below the
      # first page however long the setup took, and more than an hour before
      # the post below, so that post is an item of its own.
      line!("general", 7_200, DateTime.utc_now())
      read_now()
      {:ok, view, _html} = live(build_conn(), @path)
      before = now_items(view)
      general = Rooms.get_room!(@fleet, "general", authorize?: false)

      reads =
        page_reads_during(view.pid, fn ->
          send(view.pid, %Broadcast{event: "room_head", payload: %{room_id: general.id, seq: 1}})
          send(view.pid, {:graph_notable, @fleet})
          send(view.pid, {:proposals_changed, @fleet})
          send(view.pid, {:keys_changed, @fleet, [7]})
          render(view)
          Process.sleep(2_200)
          render(view)
        end)

      assert reads == 0
      assert now_items(view) == before

      line!("general", 0, DateTime.utc_now())
      read_now()

      assert [_new | ^before] = now_items(view)
    end

    # A reading of a fleet the page has left changes nothing on it, and the
    # fleet now on show still draws its own right after.
    test "a visitor's hall draws the reading of the fleet it shows, never one it left" do
      other = "fleet_tech_classic"
      ChainHelpers.deploy!(other)
      read_now()
      read_now(other)
      {:ok, view, _html} = live(build_conn(), @path)
      render_patch(view, Keyfleet.Fleets.path(other))

      line!("general", 0, DateTime.utc_now())
      read_now()
      refute has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))

      line!("general", 0, DateTime.utc_now(), other)
      read_now(other)
      assert has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))
    end

    # A member of both fleets, whose page reads each feed itself.
    test "a wait begun in one fleet reads nothing once the page shows another", %{conn: conn} do
      other = "fleet_tech_classic"
      ChainHelpers.deploy!(other)
      ChainHelpers.seed_cursor!(other)
      issue!(other, 1)
      {:ok, view, _html} = live(conn, @path)

      send(view.pid, {:proposals_changed, @fleet})
      render_patch(view, "#{Keyfleet.Fleets.path(other)}")
      line!("general", 0, DateTime.utc_now(), other)
      send(view.pid, {:refresh_activity, @fleet})
      refute has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))

      # The other fleet's own notice still starts its own wait.
      send(view.pid, {:proposals_changed, other})
      Process.sleep(2_200)
      assert has_element?(view, ~s(#fleet-feed-list li[data-kind="post"]))
    end

    test "Show earlier adds older items below, up to five pages, then points elsewhere",
         %{conn: conn} do
      now = DateTime.utc_now()
      # Posts turn about between two rooms, so each is an item of its own.
      for n <- 1..200, do: line!(if(rem(n, 2) == 0, do: "general", else: "coding"), n, now)

      {:ok, view, _html} = live(conn, @path)
      first = now_items(view)
      refute has_element?(view, "#fleet-feed-elsewhere")

      view |> element("#fleet-feed-earlier") |> render_click()
      both = now_items(view)

      assert Enum.take(both, length(first)) == first
      assert length(both) > length(first)
      assert length(both) == length(Enum.uniq(both))

      for _ <- 1..3, do: view |> element("#fleet-feed-earlier") |> render_click()

      refute has_element?(view, "#fleet-feed-earlier")
      assert has_element?(view, ~s(#fleet-feed-elsewhere a[href="#{@path}/rooms/general"]))
      assert has_element?(view, ~s(#fleet-feed-elsewhere a[href="#{@path}/workspace"]))
      assert has_element?(view, ~s(#fleet-feed-elsewhere a[href="#{@path}/proposals"]))
    end

    test "a proposal carried out shows, linked to the proposal", %{conn: conn} do
      ProposalHelpers.proposal!(@fleet, 1)
      ProposalHelpers.execution!(@fleet, 1, @owner)

      {:ok, view, _html} = live(conn, @path)

      line = ~s(#fleet-feed-list li[data-kind="executed"])
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
      read_now()
      {:ok, view, _html} = live(build_conn(), @path)
      view |> element("#fleet-feed-earlier") |> render_click()
      html = render(view)
      lines = text(view, "#fleet-feed-list")

      assert lines =~ "set a goal: “Survey the hull”."
      assert lines =~ "added a task."
      assert lines =~ "backed “Survey the hull” with a task."
      refute html =~ "Map every plate"
      refute has_element?(view, ~s(#fleet-feed-list a[data-item-link="#{task}"]))

      {:ok, view, _html} = live(holder, @path)
      view |> element("#fleet-feed-earlier") |> render_click()
      lines = text(view, "#fleet-feed-list")

      assert lines =~ "added a task: “Map every plate”."
      assert lines =~ "backed “Survey the hull” with “Map every plate”."
    end

    # Each channel narrows the feed to its kind of line and marks itself
    # pressed; the narrowing stays put while new lines arrive.
    test "the channels narrow the feed to one kind of line", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s(#fleet-feed[data-show="all"]))
      assert has_element?(view, ~s(#fleet-show-all[aria-pressed="true"]))

      for channel <- ~w(all chat work keys votes) do
        commands = click_commands(view, "#fleet-show-#{channel}")

        assert ["set_attr", %{"attr" => ["data-show", channel], "to" => "#fleet-feed"}] in commands

        assert [
                 "set_attr",
                 %{"attr" => ["aria-pressed", "true"], "to" => "#fleet-show-#{channel}"}
               ] in commands
      end

      line!("general", 0, DateTime.utc_now())
      send(view.pid, {:refresh_activity, @fleet})
      assert has_element?(view, ~s(#fleet-feed-list li[data-kind="post"][data-channel="chat"]))
    end

    # The feed's lines go with the hall while the map shows, so coming back
    # reads them again.
    test "the feed is there again on coming back from the map", %{conn: conn} do
      line!("general", 0, DateTime.utc_now())
      {:ok, view, _html} = live(conn, @path)
      shown = now_items(view)
      assert shown != []

      view |> element("#fleet-tab-keys") |> render_click()
      assert_patch(view, @map_path)
      assert now_items(view) == []

      view |> element("#fleet-tab-hall") |> render_click()
      assert_patch(view, @path)
      assert now_items(view) == shown
    end
  end

  describe "the way in" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      :ok
    end

    test "a holder's cards each open their Key, with no Buy button beside them", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#fleet-entry .fleet-entry__line") == "You hold 150 Keys."
      assert has_element?(view, ~s(#fleet-entry-card-1[href="#{@path}?key=1"]), "Key 1")
      assert has_element?(view, ~s(#fleet-entry-card-50[href="#{@path}?key=50"]), "Key 50")
      refute has_element?(view, "#fleet-entry-card-51")
      assert text(view, "#fleet-entry-more") == "and 100 more"
      refute has_element?(view, "#fleet-get-key")

      view |> element("#fleet-entry-card-2") |> render_click()
      assert_patch(view, @path <> "?key=2")
      assert has_element?(view, "#fleet-entry-card-2[aria-current='true']")

      {:ok, view, _html} = live(conn, @map_path)
      assert has_element?(view, ~s(#fleet-entry-card-1[href="#{@map_path}&key=1"]))
    end

    test "someone holding no Key is offered the next one" do
      read_now()
      {:ok, view, _html} = live(build_conn(), @path)

      assert has_element?(view, ~s(#fleet-entry[data-entry="buy"]))

      assert text(view, "#fleet-entry #fleet-get-key") ==
               "Join this Keyfleet by purchasing the next Key: 42.99817 USDC"

      refute has_element?(view, "#fleet-entry-cards")
    end

    # The Club's Keys are given with its Passes, never sold: its way in asks
    # for the Pass number and opens that Key.
    test "the Club opens the Key a Pass number names", %{conn: conn} do
      club = "regents_club"
      deploy!(club)
      ChainHelpers.seed_cursor!(club)
      for token_id <- 1..3, do: issue!(club, token_id, @stranger)
      read_now(club)
      path = "#{Keyfleet.Fleets.path(club)}"

      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, ~s(#fleet-entry[data-entry="pass"]))
      refute has_element?(view, "#fleet-get-key")

      assert has_element?(
               view,
               ~s(#fleet-opensea[href="https://opensea.io/collection/keyfleet?traits=%5B%7B%22traitType%22%3A%22Set%20Type%22%2C%22values%22%3A%5B%22Regents%20Club%22%5D%7D%5D"]),
               "Buy Key on OpenSea"
             )

      refute has_element?(view, "#buy-key-offer")
      refute has_element?(view, "#fleet-entry-sign-in")

      assert text(view, "#fleet-entry-pass-note") == ""

      for {refused, note} <- [
            {"4", "No Key for Pass 4"},
            {"0", "No Key for Pass 0"},
            {"abc", "Enter a Pass number"},
            {"", "Enter a Pass number"}
          ] do
        view |> form("#fleet-entry-pass", pass: refused) |> render_submit()
        refute_patched(view)
        assert text(view, "#fleet-entry-pass-note") == note
      end

      # A Pass number sent as anything but text is refused the same way.
      render_submit(view, "open_pass_key", %{"pass" => ["2"]})
      refute_patched(view)
      assert text(view, "#fleet-entry-pass-note") == "Enter a Pass number"

      view |> form("#fleet-entry-pass", pass: "2") |> render_submit()
      assert_patch(view, path <> "?key=2")
      assert text(view, "#fleet-entry-pass-note") == ""

      {:ok, view, _html} = live(build_conn(), path)
      assert has_element?(view, ~s(#fleet-entry-sign-in[data-account-target="sign-in"]))
    end

    test "/app opens the Club's hall", %{conn: conn} do
      assert redirected_to(get(conn, "/app")) == "/app/fleets/regents_club"
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
      read_now()

      {:ok, view, html} = live(conn, @path)

      row = ~s(#fleet-trying li[data-goal="#{goal}"])
      assert has_element?(view, ~s(#{row} a[data-item-link="#{goal}"][href="#{item_path(goal)}"]))

      assert text(view, "#fleet-trying-counts") ==
               "1 open goal · 2 tasks in progress · 1 taken · 1 not taken yet"

      refute html =~ "Draft the price"
      refute has_element?(view, "#fleet-trying-empty")
    end

    # The open hall draws the fleet's new reading by itself.
    test "a goal marked achieved is gone once the fleet is read again", %{conn: conn} do
      goal = goal!("Sell the first audit")
      read_now()
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, ~s(#fleet-trying li[data-goal="#{goal}"]))

      Workspace.edit(@fleet, goal, %{"status" => "achieved"})
      read_now()

      refute has_element?(view, ~s(#fleet-trying li[data-goal="#{goal}"]))
      assert has_element?(view, "#fleet-trying-empty")
    end

    test "what members wrote shows as text, with nothing that can't be seen", %{conn: conn} do
      written = "<b>Hull</b> <script>alert(1)</script>\u0007\u202Esurvey\u2066 done"

      goal = goal!(written, %{"open_questions" => [written]})
      read_now()

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
      read_now()

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

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  defp address_word("0x" <> address), do: "0x" <> String.duplicate("0", 24) <> address

  defp option_values(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
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

    render_async(view, 3_000)
  end

  # The chain the buy steps read: the Keys sold (150 unless `:minted` says),
  # the next Key's price (Key 151's unless `:price` says; `:sold_out` when the
  # manager refuses to price one), sales open since long ago, and the
  # wallet's USDC allowance to the fleet.
  defp chain!(opts) do
    selectors = %{
      allowance: Call.selector("allowance(address,address)"),
      sales_open_at: Call.selector("salesOpenAt(uint256)"),
      minted: Call.selector("totalMinted()"),
      price: Call.selector("nextPrice()")
    }

    StubClient.put_chain(chain_head(1_000), [],
      calls: fn _to, data, _hash -> answer(data, selectors, opts) end
    )
  end

  defp answer(data, selectors, opts) do
    cond do
      String.starts_with?(data, selectors.allowance) ->
        {:ok, <<Keyword.fetch!(opts, :allowance)::256>>}

      String.starts_with?(data, selectors.sales_open_at) ->
        {:ok, <<1::256>>}

      data == selectors.minted ->
        {:ok, <<Keyword.get(opts, :minted, 150)::256>>}

      data == selectors.price ->
        case Keyword.get(opts, :price, 42_998_170) do
          :sold_out -> {:error, :reverted}
          price -> {:ok, <<price::256>>}
        end

      true ->
        {:error, :no_answer}
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

  # An address no account in the shared accounts table links.
  defp unclaimed_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  # The holders the Member List shows, in its order.
  defp holders(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fleet-members-holders > li")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "fleet-members-holder-" <> wallet -> wallet end)
  end

  # The Keys shown as cards on one holder's line of the Member List.
  defp shown_keys(view, wallet) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fleet-members-holder-#{wallet} a.fleet-entry__card")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "fleet-members-card-" <> token_id -> String.to_integer(token_id) end)
  end

  # A table renamed inside the test's own transaction can't be read, the way
  # a database that refuses the read can't; the rename ends with the test.
  defp rename!(table, to) do
    Keyfleet.Repo.query!("ALTER TABLE #{Keyfleet.Repo.default_prefix()}.#{table} RENAME TO #{to}")
  end

  # A post written as key 1 `seconds` before `now`, with no notice to anyone.
  defp line!(slug, seconds, now, fleet_id \\ @fleet) do
    room = Rooms.get_room!(fleet_id, slug, authorize?: false)
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

  # What the fleet's producer does once it hears what a test changed
  # (`KeyfleetWeb.FleetNow`); it doesn't run under test.
  defp read_now(fleet_id \\ @fleet), do: FleetNow.read(fleet_id)

  # How many reads the page process `pid` makes while `fun` runs.
  defp page_reads_during(pid, fun) do
    test_pid = self()

    :telemetry.attach(
      "fleet-page-reads",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == pid, do: send(test_pid, :page_read)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach("fleet-page-reads")
    end

    count_page_reads(0)
  end

  defp count_page_reads(count) do
    receive do
      :page_read -> count_page_reads(count + 1)
    after
      0 -> count
    end
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
    |> LazyHTML.query("#fleet-feed-list > li")
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
        shown: 0,
        agents_here: nil,
        on_close: %Phoenix.LiveView.JS{}
      )

    assert html =~ "We couldn’t check who’s here just now."
    refute html =~ "No agents here yet."
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
