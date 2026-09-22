defmodule KeyFleetWeb.ShellLiveTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.AccessContext.AccountControl
  alias KeyFleet.Accounts
  alias KeyFleet.Actors.System
  alias KeyFleetWeb.Components.Shell
  alias KeyFleetWeb.RouteCatalog

  test "an anonymous visitor to /account is asked to sign in, without private content", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/account")

    assert html =~ ~s(id="app-shell")
    assert has_element?(view, "#route-content h1", "Account")
    assert has_element?(view, "#account-page button[data-account-target=sign-in]", "Sign in")
    refute has_element?(view, "#account-identity")
    refute has_element?(view, "#route-content .verified-connections")
  end

  test "an anonymous socket rejects a forged verified connection request", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app")

    render_hook(view, "request_verified_connection", %{
      "action" => "link",
      "provider" => "x"
    })

    refute_push_event(view, "verified-connections:request", _payload)
  end

  test "the switch states the theme the server just served", %{conn: conn} do
    {:ok, dark, _html} = live(conn, "/app")

    assert has_element?(
             dark,
             ~s(#theme-control button.theme-toggle[aria-pressed=false][title="Switch to Light"]),
             "Dark theme active"
           )

    {:ok, light, _html} =
      conn
      |> Plug.Test.put_req_cookie("regent_theme", "light")
      |> live("/app")

    assert has_element?(
             light,
             ~s(#theme-control button.theme-toggle[aria-pressed=true][title="Switch to Dark"]),
             "Light theme active"
           )

    assert has_element?(
             light,
             ~s(button.theme-toggle[aria-label="Color theme: Light. Activate Dark theme."])
           )
  end

  test "anonymous account control renders Sign In separately from the brand link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app")

    assert has_element?(view, ~s(#shell-brand[href="/"]), "KeyFleet")
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
      |> live("/app")

    assert has_element?(view, "#account-control [data-account-target=profile]", "0x1111…1111")

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
      |> live("/app")

    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign In")
    refute has_element?(view, "#account-control [data-account-target=sign-out]", "Disconnect")
  end

  test "signed-in account presentation survives an in-shell patch", %{conn: conn} do
    account = register_account("signed-in-patch", "0x2222222222222222222222222222222222222222")

    {:ok, view, html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/app")

    pid = view.pid
    [instance] = Regex.run(~r/data-shell-instance="(\d+)"/, html, capture: :all_but_first)

    view
    |> element("#shell-sidebar a", "Account")
    |> render_click()

    assert_patch(view, "/account")
    assert view.pid == pid
    assert render(view) =~ ~s(data-shell-instance="#{instance}")
    assert has_element?(view, "#account-control [data-account-target=profile]", "0x2222…2222")
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
      render_component(&KeyFleetWeb.AccountLive.page/1, %{
        account_control: %AccountControl{kind: :sign_in, label: "Sign In"}
      })

    assert html =~ ~s(id="account-page")
    assert html =~ ">Account<"
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
      :x,
      "account-x-subject",
      "account_user",
      "Account User",
      DateTime.utc_now(),
      %{},
      account.id,
      actor: %System{}
    )

    {view, html} = open_account(conn, account)

    refute html =~ "Sign in to see your account"
    assert has_element?(view, "#account-identity h2", "0x6666…6666")
    assert has_element?(view, "#account-identity canvas[data-holo-canvas]")
    assert has_element?(view, ".account-details code", wallet)
    assert has_element?(view, "#account-wallet-copy[data-copy-text='#{wallet}']", "Copy")
    assert has_element?(view, ".account-wallet-list code", other)
    assert has_element?(view, ".account-details dd", "Not set")
    assert has_element?(view, ".account-details dd", "Not verified")

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

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "That account is already connected to another account here."
           )
  end

  test "a connection is only called connected once the account's own record says so", %{
    conn: conn
  } do
    wallet = "0x9999999999999999999999999999999999999999"
    account = register_account("account-outcomes", wallet)

    Accounts.upsert_linked_identity!(
      :x,
      "outcome-x-subject",
      "outcome_user",
      nil,
      DateTime.utc_now(),
      %{},
      account.id,
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

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "GitHub didn’t come back connected. Try again."
           )

    # A finished disconnect whose record is still there is not a disconnection.
    render_hook(view, "refresh_verified_connections", %{"action" => "unlink", "provider" => "x"})

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "X is still connected. Try again."
           )

    {:ok, identity} =
      Accounts.get_linked_identity_by_subject(:x, "outcome-x-subject", actor: %System{})

    :ok = Accounts.remove_linked_identity(identity, actor: %System{})
    render_hook(view, "refresh_verified_connections", %{"action" => "unlink", "provider" => "x"})

    assert has_element?(view, "#account-verified-connections [role=status]", "X disconnected.")
    assert has_element?(view, "#account-verified-connections-x button", "Connect")

    # A refresh that names no request (a plain sign-in refresh) re-reads quietly.
    render_hook(view, "refresh_verified_connections", %{"error" => nil})
    refute has_element?(view, "#account-verified-connections [role=status]")
    refute has_element?(view, "#account-verified-connections [role=alert]")

    # A browser-side failure is reported as one, whatever the record says.
    render_hook(view, "refresh_verified_connections", %{
      "error" => "failed",
      "action" => "link",
      "provider" => "x"
    })

    assert has_element?(
             view,
             "#account-verified-connections [role=alert]",
             "That connection couldn’t be verified. Try again."
           )
  end

  test "in-shell navigation keeps the LiveView and shell identity", %{conn: conn} do
    {:ok, view, html} = live(conn, "/app")
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

  defp open_account(conn, account) do
    {:ok, view, html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/account")

    {view, html}
  end

  defp register_account(suffix, wallet) do
    assert {:ok, account} =
             Accounts.register_verified("did:privy:#{suffix}", wallet, [wallet], actor: %System{})

    account
  end

  defp render_shell(account_control) do
    route_spec = RouteCatalog.fetch!(:app, %{})

    render_component(&Shell.shell/1,
      route_spec: route_spec,
      account_control: account_control,
      shell_instance: 1,
      theme: "dark",
      content: [%{inner_block: fn _, _ -> "Fixture content" end}]
    )
  end
end
