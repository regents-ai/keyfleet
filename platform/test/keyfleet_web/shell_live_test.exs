defmodule KeyfleetWeb.ShellLiveTest do
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  alias Keyfleet.AccessContext.AccountControl
  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Components.Shell
  alias KeyfleetWeb.FleetNow
  alias KeyfleetWeb.RouteCatalog

  test "an anonymous visitor to /account is asked to sign in, without private content", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/account")

    assert html =~ ~s(id="app-shell")
    assert has_element?(view, "#route-content h1", "Profile")
    assert has_element?(view, "#shell-tabs a[aria-current=page]", "Profile")
    assert has_element?(view, "#account-page button[data-account-target=sign-in]", "Sign in")
    refute has_element?(view, "#account-identity")
    refute has_element?(view, "#route-content .verified-connections")
  end

  test "the sidebar marks a fleet on every one of its pages", %{conn: conn} do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!("fleet_tech_classic")
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    {:ok, view, _html} = live(conn, "/classic/1/rooms/general")

    assert has_element?(view, "#shell-sidebar a[aria-current=page]", "Classic #1")
  end

  test "an anonymous socket rejects a forged verified connection request", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/account")

    render_hook(view, "request_verified_connection", %{
      "action" => "link",
      "provider" => "x"
    })

    refute_push_event(view, "verified-connections:request", _payload)
  end

  test "the switch carries a sentence for each theme, whatever was served", %{conn: conn} do
    for cookie <- [nil, "light", "dark"] do
      conn = if cookie, do: Plug.Test.put_req_cookie(conn, "regent_theme", cookie), else: conn
      {:ok, view, _html} = live(conn, "/account")

      assert has_element?(
               view,
               ~s(#theme-control button.theme-toggle[title="Switch between light and dark"])
             )

      assert has_element?(
               view,
               "#theme-control .rg-theme-toggle__state--dark",
               "Dark theme on. Switch to light theme."
             )

      assert has_element?(
               view,
               "#theme-control .rg-theme-toggle__state--light",
               "Light theme on. Switch to dark theme."
             )
    end
  end

  test "anonymous account control renders Sign in separately from the brand link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/account")

    assert has_element?(view, ~s(#shell-brand[href="/"]), "Keyfleet")
    assert has_element?(view, "#shell-brand .shell-brand__mark img.shell-brand__mark-light")
    assert has_element?(view, "#shell-brand .shell-brand__mark img.shell-brand__mark-dark")
    assert has_element?(view, "#theme-control button.theme-toggle[data-theme-toggle]")
    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign in")

    assert has_element?(
             view,
             "#account-control #account-auth-status[role=status][aria-live=polite][aria-atomic=true][phx-update=ignore][hidden]"
           )
  end

  test "the signed-in name opens the side panel, which holds Sign out", %{conn: conn} do
    account = register_account("signed-in-control", "0x1111111111111111111111111111111111111111")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    assert has_element?(view, "#account-control [data-account-target=profile]", "0x1111..1111")

    assert has_element?(
             view,
             "#account-control img.account-avatar[src^='data:image/svg+xml;base64,']"
           )

    assert has_element?(
             view,
             "#account-control button#account-chip[data-aside-toggle][aria-controls=shell-aside]"
           )

    refute has_element?(view, "#account-control [data-account-target=sign-out]")
    # Fleets beside the name is the homepage's alone.
    refute has_element?(view, "#shell-fleets")

    assert has_element?(
             view,
             "#shell-aside #shell-account button[type=button][data-account-target=sign-out]",
             "Sign out"
           )

    assert has_element?(
             view,
             ~s{#shell-account a[href="/account"]:not([target])},
             "Manage Account"
           )

    assert has_element?(
             view,
             ~s{#shell-agents a[href="/account#account-agents"]:not([target])},
             "Manage"
           )

    assert has_element?(view, "#shell-header #shell-aside-button[data-aside-toggle]")
    assert has_element?(view, "#theme-control button.theme-toggle[data-theme-toggle]")
    refute has_element?(view, "#account-control [phx-click]")
  end

  test "the side panel pairs only an offered agent, with a new code",
       %{conn: conn} do
    account = register_account("pairing-box", "0x2222222222222222222222222222222222222222")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    box = "#shell-pairing-box"
    assert has_element?(view, "#{box} input[name=harness][value=hermes]")
    refute has_element?(view, "#{box} input[name=harness][value=chatgpt]")

    html = view |> element(box) |> render_change(%{"harness" => "hermes"})

    assert [_, code] = Regex.run(~r/Pairing code: (\S+)/, html)
    refute code =~ ~r/^X+$/
    assert has_element?(view, "#{box} input[name=harness][value=hermes][checked]")

    view |> element(box) |> render_change(%{"harness" => "chatgpt"})
    assert has_element?(view, "#{box} input[name=harness][value=hermes][checked]")
  end

  test "the side panel makes pairing codes only within the account's allowance",
       %{conn: conn} do
    limits = Application.fetch_env!(:keyfleet, :limits)
    on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)

    Application.put_env(
      :keyfleet,
      :limits,
      Keyword.put(limits, :pairing_codes, limit: 1, window_seconds: 3600)
    )

    account = register_account("pairing-budget", "0x5555555555555555555555555555555555555555")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    box = "#shell-pairing-box"
    html = view |> element(box) |> render_change(%{})
    refute html =~ ~r/Pairing code: (?!X+\b)\S+/

    html = view |> element(box) |> render_change(%{"harness" => "hermes"})
    assert [_, code] = Regex.run(~r/Pairing code: (?!X+\b)(\S+)/, html)

    html = view |> element(box) |> render_change(%{"harness" => "hermes"})
    refute html =~ code
    refute html =~ ~r/Pairing code: (?!X+\b)\S+/
  end

  test "the Account page lists a paired agent with its picture and harness", %{conn: conn} do
    account = register_account("paired-agent", "0x3333333333333333333333333333333333333333")

    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: "did:privy:paired-agent"}
      )

    RegentAgents.pair_agent!(code, "Astra", :hermes,
      actor: %RegentAgents.Agent{wallet: "0x4444444444444444444444444444444444444444"}
    )

    {view, _html} = open_account(conn, account)

    assert has_element?(view, "#account-agents li", "Astra")

    assert has_element?(
             view,
             ~s(#account-agents li img[src="/images/regent-ui/agents/hermes.png"])
           )

    assert has_element?(view, "#account-agents li", "Hermes")
  end

  test "stale wallet evidence cannot retain protected human shell access", %{conn: conn} do
    account =
      register_account("stale-wallet-control", "0x9999999999999999999999999999999999999999")

    assert {:ok, _invalidated} = Accounts.refresh_verified(account, nil, [], actor: %System{})

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign in")
    refute has_element?(view, "[data-account-target=sign-out]")
    refute has_element?(view, "#shell-aside")
  end

  test "signed-in account presentation survives an in-shell patch", %{conn: conn} do
    account = register_account("signed-in-patch", "0x2222222222222222222222222222222222222222")

    {:ok, view, html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/syndicate/1")

    pid = view.pid
    [instance] = Regex.run(~r/data-shell-instance="(\d+)"/, html, capture: :all_but_first)

    view
    |> element("#shell-sidebar a", "Account")
    |> render_click()

    assert_patch(view, "/account")
    assert view.pid == pid
    assert render(view) =~ ~s(data-shell-instance="#{instance}")
    assert has_element?(view, "#account-control [data-account-target=profile]", "0x2222..2222")
    assert has_element?(view, "#shell-account [data-account-target=sign-out]", "Sign out")
  end

  test "the signed-in account chip shows the picture and the name, and opens the side panel" do
    html =
      render_shell(%AccountControl{
        kind: :signed_in,
        label: "Ada",
        avatar_src: "data:image/svg+xml;base64,PHN2Zy8+"
      })

    assert html =~ ~r/data-account-target="profile">\s*Ada\s*</
    assert html =~ ~s(class="account-avatar")
    assert html =~ ~s(src="data:image/svg+xml;base64,PHN2Zy8+")
    assert html =~ ~r/<button[^>]*id="account-chip"[^>]*data-aside-toggle/s
    assert html =~ ~r/<aside[^>]*id="shell-aside"/
    assert html =~ "Sign out"
    refute html =~ "Sign Out"
  end

  test "Account owns its own page rather than relabeling the whole shell" do
    html =
      render_component(&KeyfleetWeb.AccountLive.profile/1, %{
        account_control: %AccountControl{kind: :sign_in, label: "Sign in"}
      })

    assert html =~ ~s(id="account-page")
    assert html =~ ">Profile<"
    assert html =~ "Sign in to see your account"
    refute html =~ "Verified connections"
  end

  test "Account shows the signed-in person, their wallets and connections", %{conn: conn} do
    wallet = "0x6666666666666666666666666666666666666666"
    other = "0x7777777777777777777777777777777777777777"

    assert {:ok, account} =
             Accounts.register_verified("did:privy:account-page", wallet, [wallet, other],
               actor: %System{}
             )

    Accounts.upsert_linked_identity!(
      %{
        provider: :x,
        subject: "account-x-subject",
        username: "account_user",
        display_name: "Account User",
        verified_at: DateTime.utc_now(),
        metadata: %{},
        human_account_id: account.id
      },
      actor: %System{}
    )

    {view, html} = open_account(conn, account)

    refute html =~ "Sign in to see your account"

    assert has_element?(
             view,
             "#account-identity h2 #account-name-copy[data-copy-text='#{wallet}']"
           )

    assert has_element?(view, "#account-identity canvas[data-holo-canvas]")
    assert has_element?(view, ".account-details dd", "Not set")
    assert has_element?(view, "#account-page button[data-account-target=sign-out]", "Sign out")

    view |> element("#shell-tabs a", "Wallets") |> render_click()
    assert_patch(view, "/account/wallets")
    assert has_element?(view, "#shell-sidebar a[aria-current=page]", "Account")

    assert has_element?(
             view,
             "#wallets-list-#{wallet} .rg-address__label",
             RegentFormat.short_address(wallet)
           )

    assert has_element?(view, "#wallets-list-#{wallet}-address-copy[data-copy-text='#{wallet}']")

    assert has_element?(
             view,
             "#wallets-list-#{wallet}-address-explorer[href='https://basescan.org/address/#{wallet}']"
           )

    assert has_element?(view, "#wallets-list-#{other}-address-copy[data-copy-text='#{other}']")

    view |> element("#shell-tabs a", "Connections") |> render_click()
    assert_patch(view, "/account/connections")
    render_async(view)

    assert has_element?(
             view,
             ~s(#account-verified-connections-x a[href="https://x.com/account_user"]),
             "@account_user"
           )

    assert has_element?(view, "#account-verified-connections-x button", "Disconnect")
    assert has_element?(view, "#account-verified-connections-github", "Not connected")
    assert has_element?(view, "#account-verified-connections-github button", "Connect")
    refute render(view) =~ "account-x-subject"

    view
    |> element("#account-verified-connections-x button", "Disconnect")
    |> render_click()

    assert_push_event(view, "verified-connections:request", %{
      action: :unlink,
      provider: :x,
      subject: "account-x-subject"
    })

    assert has_element?(view, "#account-verified-connections [role=status]", "Disconnecting X")

    render_hook(view, "refresh_verified_connections", %{"error" => "already-connected"})
    render_async(view)

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "That account is already connected to another account here."
           )
  end

  test "the side panel and Account say which wallet is the Regents wallet and which is active",
       %{conn: conn} do
    own = "0x8888888888888888888888888888888888888888"
    regents = "0xabababababababababababababababababababab"
    elsewhere = "0x1212121212121212121212121212121212121212"

    assert {:ok, account} =
             Accounts.register_verified("did:privy:account-wallets", own, [own, regents],
               actor: %System{}
             )

    {view, _html} = open_account(conn, account)

    # Until the browser says, each wallet shows and copies as linked, with no mark.
    for list <- ~w(#shell-wallets #account-wallets), address <- [own, regents] do
      assert has_element?(
               view,
               "#{list}-#{address} .account-wallets__label",
               "Linked to this account"
             )

      assert has_element?(view, "#{list}-#{address}-address-copy[data-copy-text='#{address}']")
    end

    refute has_element?(view, "#shell-wallets .rg-status")

    seen!(
      view,
      "#shell-wallets",
      "0x" <> String.upcase("abababababababababababababababababababab"),
      [regents]
    )

    assert has_element?(view, "#shell-wallets-#{own} .account-wallets__label", "Your wallet")
    refute has_element?(view, "#shell-wallets-#{own} .rg-status")

    assert has_element?(
             view,
             "#shell-wallets-#{regents} .account-wallets__label",
             "Regents wallet"
           )

    assert has_element?(view, "#shell-wallets-#{regents} .rg-status", "Active")

    # An active wallet the account isn't linked to is shown, and said to be one.
    seen!(view, "#account-wallets", elsewhere, [regents])

    assert has_element?(
             view,
             "#account-wallets-#{elsewhere} .account-wallets__label",
             "Not linked to this account"
           )

    assert has_element?(view, "#account-wallets-#{elsewhere} .rg-status", "Active")

    assert has_element?(
             view,
             "#account-wallets-#{elsewhere}-address-copy[data-copy-text='#{elsewhere}']"
           )

    refute has_element?(view, "#account-wallets-#{regents} .rg-status")
  end

  test "Account lists the keys the person's wallets hold, fleet by fleet", %{conn: conn} do
    wallet = "0x5555555555555555555555555555555555555555"
    other = "0x4444444444444444444444444444444444444444"
    Fleets.bootstrap_catalog!()
    ChainHelpers.open_cursor!("fibonacci_cascade")
    ChainHelpers.open_cursor!("fleet_tech_classic")

    assert {:ok, account} =
             Accounts.register_verified("did:privy:account-keys", wallet, [wallet, other],
               actor: %System{}
             )

    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#account-keys p", "Your wallets don’t hold any Keys yet.")

    issue!("fleet_tech_classic", 2, wallet)
    issue!("fibonacci_cascade", 5, other)
    issue!("fibonacci_cascade", 3, wallet)
    issue!("fibonacci_cascade", 4, "0x" <> String.duplicate("3", 40))

    {view, html} = open_account(conn, account)

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("#account-keys h3")
           |> LazyHTML.text() ==
             "Classic #1Cascade #1"

    assert keys_listed(html) == [
             "/classic/1?key=2",
             "/cascade/1?key=3",
             "/cascade/1?key=5"
           ]

    view |> element("#account-keys a", "Key 5") |> render_click()
    assert_patch(view, "/cascade/1?key=5")
  end

  test "where a person holds several Keys of a fleet, Account sets the one they post as", %{
    conn: conn
  } do
    wallet = "0x6666666666666666666666666666666666666666"
    Fleets.bootstrap_catalog!()
    ChainHelpers.open_cursor!("fibonacci_cascade")
    ChainHelpers.open_cursor!("fleet_tech_classic")

    assert {:ok, account} =
             Accounts.register_verified("did:privy:posting-key", wallet, [wallet],
               actor: %System{}
             )

    issue!("fleet_tech_classic", 2, wallet)
    issue!("fibonacci_cascade", 25, wallet)
    issue!("fibonacci_cascade", 41, wallet)

    {view, _html} = open_account(conn, account)
    choice = "#account-posting-key-fibonacci_cascade"

    refute has_element?(view, "#account-posting-key-fleet_tech_classic")
    assert has_element?(view, "#{choice} option[selected]", "Key 25")

    view |> element(choice) |> render_change(%{"token_id" => "41"})

    assert has_element?(view, "#{choice} [role=status]", "Saved.")
    assert has_element?(view, "#{choice} option[selected]", "Key 41")

    person = Keyfleet.Actors.Human.for_account(account)
    assert %{token_id: 41} = Keys.identity(person, "fibonacci_cascade")

    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#{choice} option[selected]", "Key 41")
  end

  test "a connection is only called connected once the account's own record says so", %{
    conn: conn
  } do
    wallet = "0x9999999999999999999999999999999999999999"
    account = register_account("account-outcomes", wallet)

    Accounts.upsert_linked_identity!(
      %{
        provider: :x,
        subject: "outcome-x-subject",
        username: "outcome_user",
        display_name: nil,
        verified_at: DateTime.utc_now(),
        metadata: %{},
        human_account_id: account.id
      },
      actor: %System{}
    )

    {view, _html} = open_account(conn, account, "/account/connections")

    view |> element("#account-verified-connections-github button", "Connect") |> render_click()
    assert_push_event(view, "verified-connections:request", %{action: :link, provider: :github})

    assert has_element?(
             view,
             "#account-verified-connections [role=status]",
             "Taking you to GitHub to approve the connection."
           )

    view |> element("#account-verified-connections-farcaster button", "Connect") |> render_click()

    assert has_element?(
             view,
             "#account-verified-connections [role=status]",
             "Scan the code with Farcaster to approve the connection."
           )

    # The browser says its side finished, but nothing was recorded for GitHub.
    render_hook(view, "refresh_verified_connections", %{
      "action" => "link",
      "provider" => "github"
    })

    render_async(view)

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "GitHub didn’t come back connected. Try again."
           )

    # A finished disconnect whose record is still there is not a disconnection.
    render_hook(view, "refresh_verified_connections", %{"action" => "unlink", "provider" => "x"})
    render_async(view)

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "X is still connected. Try again."
           )

    {:ok, identity} =
      Accounts.get_linked_identity_by_subject(:x, "outcome-x-subject", actor: %System{})

    :ok = Accounts.remove_linked_identity(identity, actor: %System{})
    render_hook(view, "refresh_verified_connections", %{"action" => "unlink", "provider" => "x"})
    render_async(view)

    assert has_element?(view, "#account-verified-connections [role=status]", "X disconnected.")
    assert has_element?(view, "#account-verified-connections-x button", "Connect")

    # A refresh that names no request (a plain sign-in refresh) re-reads quietly.
    render_hook(view, "refresh_verified_connections", %{"error" => nil})
    render_async(view)
    refute has_element?(view, "#account-verified-connections [role=status]")
    refute has_element?(view, "#account-verified-connections [role=alert]")

    # A browser-side failure is reported as one, whatever the record says.
    render_hook(view, "refresh_verified_connections", %{
      "error" => "failed",
      "action" => "link",
      "provider" => "x"
    })

    render_async(view)

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "That connection couldn’t be verified. Try again."
           )
  end

  # Signed out, the sidebar names the account page as the header's button does.
  test "in-shell navigation keeps the LiveView and shell identity", %{conn: conn} do
    {:ok, view, html} = live(conn, "/syndicate/1")
    pid = view.pid
    [instance] = Regex.run(~r/data-shell-instance="(\d+)"/, html, capture: :all_but_first)

    view
    |> element("#shell-sidebar a", "Sign in")
    |> render_click()

    assert_patch(view, "/account")
    assert view.pid == pid
    assert render(view) =~ ~s(data-shell-instance="#{instance}")
    assert has_element?(view, "#route-content h1", "Profile")
  end

  # A visitor's hall is drawn from the fleet's reading every such page
  # shares (`KeyfleetWeb.FleetNow`), which hears the fleet's rooms, workspace
  # and votes once for all of them; the page itself hears only the fleet's
  # Keys, for what its reader holds, beside the readings it shows.
  test "a visitor's page hears what anyone hears of the fleet on show, and stops hearing the fleet it left",
       %{conn: conn} do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!("fleet_tech_classic")
    ChainHelpers.deploy!("fibonacci_cascade")
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    FleetNow.read("fibonacci_cascade")
    {:ok, view, _html} = live(conn, "/classic/1/rooms/general")

    # the Public room's own posts too, while it is open (`Keyfleet.Rooms.Message.topic/2`).
    {[_general], heard} =
      Enum.split_with(topics(view), &String.starts_with?(&1, "public:room:fleet_tech_classic:"))

    assert heard ==
             Enum.sort([
               Keys.topic("fleet_tech_classic"),
               Rooms.topic("fleet_tech_classic", :public)
             ])

    # Neither its rooms, its workspace's notable changes nor its votes.
    render_patch(view, "/cascade/1")
    assert has_element?(view, "#fleet-hall")

    assert Enum.reject(topics(view), &String.starts_with?(&1, "shared_reading:")) == [
             Keys.topic("fibonacci_cascade")
           ]
  end

  test "the Account page looks at, renames and unpairs a paired agent", %{conn: conn} do
    account = register_account("agent-manage", "0x3434343434343434343434343434343434343434")

    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: "did:privy:agent-manage"}
      )

    RegentAgents.pair_agent!(code, "Astra", :hermes,
      actor: %RegentAgents.Agent{wallet: "0x4545454545454545454545454545454545454545"}
    )

    {view, _html} = open_account(conn, account)

    view |> element("#account-agents button", "See what it has done") |> render_click()
    render_async(view)

    assert has_element?(view, "#account-agent-dialog h2", "Astra")
    assert has_element?(view, "#account-agent-dialog", "spent for you on Regent sites.")

    view
    |> form("#account-agent-dialog form.rg-account__name", %{"name" => "Sol​"})
    |> render_submit()

    assert has_element?(view, "#account-agent-dialog [role=alert]", "That name can’t be used.")
    assert has_element?(view, "#account-agents li", "Astra")

    view
    |> form("#account-agent-dialog form.rg-account__name", %{"name" => "Sol"})
    |> render_submit()

    assert has_element?(
             view,
             "#account-agent-dialog [role=status]",
             "Saved. This agent is now called Sol on every Regent site."
           )

    assert has_element?(view, "#account-agents li", "Sol")

    view |> element("#account-agent-dialog button", "Unpair") |> render_click()

    refute has_element?(view, "#account-agent-dialog")
    refute has_element?(view, "#account-agents li")
    assert has_element?(view, "#account-agents [role=status]", "Sol is unpaired.")

    assert {:ok, []} =
             RegentAgents.list_my_agents(
               actor: %RegentAgents.Person{privy_user_id: "did:privy:agent-manage"}
             )
  end

  test "Account says whether World ID has verified the person", %{conn: conn} do
    account = register_account("world-id", "0x5656565656565656565656565656565656565656")

    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#account-world-id dd", "Not verified")

    Keyfleet.Repo.query!(
      "UPDATE regent_names.platform_human_users SET world_verified_at = '2026-10-18 09:30:00' WHERE id = $1",
      [account.id]
    )

    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#account-world-id dd", "Verified on 18 October 2026")
  end

  test "Account shows the wallet's ENS name, or why there is none", %{conn: conn} do
    wallet = "0x6767676767676767676767676767676767676767"
    account = register_account("ens-states", wallet)

    ens_row!(account, wallet, nil, "done")
    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#account-ens-name dd", "No primary name set for this wallet")

    ens_row!(account, wallet, "crew.eth", "done")
    {view, _html} = open_account(conn, account)
    assert has_element?(view, "#account-ens .rg-address__label", "crew.eth")
    assert has_element?(view, "#account-ens-copy[data-copy-text='#{wallet}']")

    # A name read for a wallet the account no longer uses is never shown.
    ens_row!(account, "0x" <> String.duplicate("8", 40), "old.eth", "done")
    {view, _html} = open_account(conn, account)
    refute render(view) =~ "old.eth"
  end

  test "opening Account asks Ethereum again after a failed lookup", %{conn: conn} do
    wallet = "0x7878787878787878787878787878787878787878"
    account = register_account("ens-retry", wallet)
    ens_row!(account, wallet, nil, "failed")

    rpc = Application.get_env(:keyfleet, :ethereum_read_rpc_url)
    Application.put_env(:keyfleet, :ethereum_read_rpc_url, "http://127.0.0.1:1")
    on_exit(fn -> Application.put_env(:keyfleet, :ethereum_read_rpc_url, rpc) end)

    {view, _html} = open_account(conn, account)

    assert_enqueued(worker: Keyfleet.Accounts.EnsIdentity.Workers.LookUp)

    assert has_element?(
             view,
             "#account-ens-name dd[role=status]",
             "Checking Ethereum for a primary name…"
           )
  end

  defp topics(view), do: Keyfleet.PubSub |> Registry.keys(view.pid) |> Enum.sort()

  # What the page's wallet hook reports for the wallet list `list`.
  defp seen!(view, list, active, regents),
    do:
      view
      |> with_target(list)
      |> render_hook("wallets_seen", %{"active" => active, "regents" => regents})

  defp open_account(conn, account, path \\ "/account") do
    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live(path)

    {view, render_async(view)}
  end

  defp keys_listed(html),
    do:
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#account-keys li a")
      |> LazyHTML.attribute("href")

  defp issue!(fleet_id, token_id, owner) do
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
      actor: %System{}
    )
  end

  # The ENS lookup the account's open pages read, as the lookup job leaves it.
  defp ens_row!(account, wallet, name, state) do
    Keyfleet.Repo.query!(
      "INSERT INTO keyfleet_app.account_ens_identities (id, human_account_id, wallet_address, " <>
        "ens_name, lookup_state, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $2, $3, $4, now(), now()) " <>
        "ON CONFLICT (human_account_id) DO UPDATE SET wallet_address = $2, ens_name = $3, lookup_state = $4",
      [account.id, wallet, name, state]
    )
  end

  defp register_account(suffix, wallet) do
    assert {:ok, account} =
             Accounts.register_verified("did:privy:#{suffix}", wallet, [wallet], actor: %System{})

    account
  end

  defp render_shell(account_control) do
    route_spec = RouteCatalog.fetch!("/account")

    render_component(&Shell.shell/1,
      route_spec: route_spec,
      account_control: account_control,
      shell_instance: 1,
      get_key: true,
      content: [%{inner_block: fn _, _ -> "Fixture content" end}]
    )
  end
end
