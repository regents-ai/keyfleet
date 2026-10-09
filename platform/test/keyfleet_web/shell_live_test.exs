defmodule KeyfleetWeb.ShellLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.AccessContext.AccountControl
  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Code
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Components.Shell
  alias KeyfleetWeb.RouteCatalog

  test "an anonymous visitor to /account is asked to sign in, without private content", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/account")

    assert html =~ ~s(id="app-shell")
    assert has_element?(view, "#route-content h1", "Account")
    assert has_element?(view, "#account-page button[data-account-target=sign-in]", "Sign In")
    refute has_element?(view, "#account-identity")
    refute has_element?(view, "#route-content .verified-connections")
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

  test "anonymous account control renders Sign In separately from the brand link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/account")

    assert has_element?(view, ~s(#shell-brand[href="/"]), "Keyfleet")
    assert has_element?(view, "#shell-brand .shell-brand__mark img.shell-brand__mark-light")
    assert has_element?(view, "#shell-brand .shell-brand__mark img.shell-brand__mark-dark")
    assert has_element?(view, "#theme-control button.theme-toggle[data-theme-toggle]")
    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign In")

    assert has_element?(
             view,
             "#account-control #account-auth-status[role=status][aria-live=polite][aria-atomic=true][phx-update=ignore][hidden]"
           )
  end

  test "signed-in account control renders its address avatar and requested menu", %{conn: conn} do
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
             "#account-control button[type=button][data-account-target=sign-out]",
             "Disconnect"
           )

    assert has_element?(view, "#account-control a[data-account-menu-item=account]", "Account")
    assert has_element?(view, "#theme-control button.theme-toggle[data-theme-toggle]")
    refute has_element?(view, "#account-control [phx-click]")
  end

  test "stale wallet evidence cannot retain protected human shell access", %{conn: conn} do
    account =
      register_account("stale-wallet-control", "0x9999999999999999999999999999999999999999")

    assert {:ok, _invalidated} = Accounts.refresh_verified(account, nil, [], actor: %System{})

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign In")
    refute has_element?(view, "#account-control [data-account-target=sign-out]", "Disconnect")
  end

  test "signed-in account presentation survives an in-shell patch", %{conn: conn} do
    account = register_account("signed-in-patch", "0x2222222222222222222222222222222222222222")

    {:ok, view, html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/app/fleets/fibonacci_syndicate")

    pid = view.pid
    [instance] = Regex.run(~r/data-shell-instance="(\d+)"/, html, capture: :all_but_first)

    view
    |> element("#shell-sidebar a", "Account")
    |> render_click()

    assert_patch(view, "/account")
    assert view.pid == pid
    assert render(view) =~ ~s(data-shell-instance="#{instance}")
    assert has_element?(view, "#account-control [data-account-target=profile]", "0x2222..2222")
    assert has_element?(view, "#account-control [data-account-target=sign-out]", "Disconnect")
  end

  test "the signed-in account menu shows the picture, the name, Account and Disconnect" do
    html =
      render_shell(%AccountControl{
        kind: :signed_in,
        label: "Ada",
        avatar_src: "data:image/svg+xml;base64,PHN2Zy8+"
      })

    assert html =~ ~r/data-account-target="profile">\s*Ada\s*</
    assert html =~ ~s(class="account-avatar")
    assert html =~ ~s(src="data:image/svg+xml;base64,PHN2Zy8+")
    assert html =~ ~s(href="/account")
    assert html =~ ~s(data-account-menu-item="account")
    assert html =~ "Disconnect"
    refute html =~ "Sign Out"
  end

  test "Account owns its own page rather than relabeling the whole shell" do
    html =
      render_component(&KeyfleetWeb.AccountLive.page/1, %{
        account_control: %AccountControl{kind: :sign_in, label: "Sign In"},
        verified_connections: %KeyfleetWeb.Read{}
      })

    assert html =~ ~s(id="account-page")
    assert html =~ ">Account<"
    assert html =~ "Sign In to see your account"
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

    refute html =~ "Sign In to see your account"
    assert has_element?(view, "#account-identity h2", "0x6666..6666")
    assert has_element?(view, "#account-identity canvas[data-holo-canvas]")
    assert has_element?(view, ".account-details code", wallet)
    assert has_element?(view, "#account-wallet-copy[data-copy-text='#{wallet}']", "Copy")
    assert has_element?(view, ".account-wallet-list code", other)
    assert has_element?(view, ".account-details dd", "Not set")

    assert has_element?(
             view,
             ~s(#account-verified-connections-x a[href="https://x.com/account_user"]),
             "@account_user"
           )

    assert has_element?(view, "#account-verified-connections-x button", "Disconnect")
    assert has_element?(view, "#account-verified-connections-github", "Not connected")
    assert has_element?(view, "#account-verified-connections-github button", "Connect")
    refute render(view) =~ "account-x-subject"
    assert has_element?(view, "#account-page button[data-account-target=sign-out]", "Sign out")

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
             "/app/fleets/fleet_tech_classic?key=2",
             "/app/fleets/fibonacci_cascade?key=3",
             "/app/fleets/fibonacci_cascade?key=5"
           ]

    view |> element("#account-keys a", "Key 5") |> render_click()
    assert_patch(view, "/app/fleets/fibonacci_cascade?key=5")
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

    {view, _html} = open_account(conn, account)

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

  test "in-shell navigation keeps the LiveView and shell identity", %{conn: conn} do
    {:ok, view, html} = live(conn, "/app/fleets/fibonacci_syndicate")
    pid = view.pid
    [instance] = Regex.run(~r/data-shell-instance="(\d+)"/, html, capture: :all_but_first)

    view
    |> element("#shell-sidebar a", "Account")
    |> render_click()

    assert_patch(view, "/account")
    assert view.pid == pid
    assert render(view) =~ ~s(data-shell-instance="#{instance}")
    assert has_element?(view, "#route-content h1", "Account")
  end

  test "a patch to another fleet's page stops hearing the fleet it left", %{conn: conn} do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic/rooms/general")

    assert topics(view) ==
             Enum.sort([
               Keys.topic("fleet_tech_classic"),
               Rooms.fleet_topic("fleet_tech_classic")
             ])

    render_patch(view, "/app/fleets/fibonacci_cascade")

    assert topics(view) ==
             Enum.sort([
               Keys.topic("fibonacci_cascade"),
               Rooms.fleet_topic("fibonacci_cascade"),
               Graph.head_topic("fibonacci_cascade"),
               Code.topic("fibonacci_cascade"),
               Proposals.topic("fibonacci_cascade")
             ])
  end

  defp topics(view), do: Keyfleet.PubSub |> Registry.keys(view.pid) |> Enum.sort()

  defp open_account(conn, account) do
    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

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

  defp register_account(suffix, wallet) do
    assert {:ok, account} =
             Accounts.register_verified("did:privy:#{suffix}", wallet, [wallet], actor: %System{})

    account
  end

  defp render_shell(account_control) do
    route_spec = RouteCatalog.fetch!(:account, %{})

    render_component(&Shell.shell/1,
      route_spec: route_spec,
      account_control: account_control,
      shell_instance: 1,
      content: [%{inner_block: fn _, _ -> "Fixture content" end}]
    )
  end
end
