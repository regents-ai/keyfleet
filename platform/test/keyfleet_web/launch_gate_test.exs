defmodule KeyfleetWeb.LaunchGateTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import KeyfleetWeb.RefusalHelpers

  alias Keyfleet.Accounts
  alias KeyfleetWeb.{ContentSecurityPolicy, PublicDocuments}
  alias KeyfleetWeb.Live.LaunchGateHook
  alias KeyfleetWeb.Plugs.LaunchGate

  @closed_pages ~w(/ /opportunities /account /app /syndicate/1
                   /syndicate/1/keys/1 /fleets/fibonacci_syndicate /no-such-page)
  @reading ~w(/agents /agents/dots /docs /changelog /about /privacy /terms)
  @closed_message "This part of the site isn't open yet."

  setup do
    on_exit(&open_surfaces/0)

    :ok
  end

  defp close_surfaces, do: Application.put_env(:keyfleet, :app_surfaces, false)
  defp open_surfaces, do: Application.put_env(:keyfleet, :app_surfaces, true)

  test "one switch reads both explicit states" do
    open_surfaces()
    assert LaunchGate.app_surfaces_enabled?()

    close_surfaces()
    refute LaunchGate.app_surfaces_enabled?()
  end

  test "the switch takes effect between requests of one running build" do
    assert get(build_conn(), "/account").status == 200

    close_surfaces()
    assert redirected_to(get(build_conn(), "/account")) == "/early"

    open_surfaces()
    assert get(build_conn(), "/account").status == 200
  end

  test "the boot takes only on or off, production must say which, and records the state" do
    original = System.get_env("KEYFLEET_APP_SURFACES")
    on_exit(fn -> restore_setting(original) end)
    System.delete_env("KEYFLEET_APP_SURFACES")

    assert_raise RuntimeError, ~s(KEYFLEET_APP_SURFACES must be "on" or "off", got nil), fn ->
      read_runtime_config(:prod)
    end

    assert {config, _log} = read_runtime_config(:test)
    refute config |> Keyword.get(:keyfleet, []) |> Keyword.has_key?(:app_surfaces)

    System.put_env("KEYFLEET_APP_SURFACES", "on")
    assert {config, log} = read_runtime_config(:test)
    assert config[:keyfleet][:app_surfaces]
    assert log =~ "App surfaces enabled"

    System.put_env("KEYFLEET_APP_SURFACES", "off")
    assert {config, log} = read_runtime_config(:test)
    refute config[:keyfleet][:app_surfaces]
    assert log =~ "App surfaces disabled"

    System.put_env("KEYFLEET_APP_SURFACES", "yes")

    assert_raise RuntimeError, ~s(KEYFLEET_APP_SURFACES must be "on" or "off", got "yes"), fn ->
      read_runtime_config(:test)
    end
  end

  test "while closed, every other page a browser opens is sent to the early-access page" do
    close_surfaces()

    for path <- @closed_pages do
      conn = get(build_conn(), path)

      assert redirected_to(conn, 302) == "/early", "#{path} was not sent to /early"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ ~s(id="app-shell")
    end
  end

  test "while closed, the API, sign-in and the other JSON documents answer one plain 503" do
    close_surfaces()

    for conn <- [
          get(build_conn(), "/api/v1/fleets"),
          get(build_conn(), "/api/v1/profile"),
          get(build_conn(), "/auth/session"),
          get(build_conn(), "/auth/csrf"),
          post(build_conn(), "/auth/privy/session", %{}),
          delete(build_conn(), "/auth/privy/session"),
          get(build_conn(), "/openapi.json"),
          get(build_conn(), "/capabilities.json"),
          get(build_conn(), "/.well-known/api-catalog"),
          get(build_conn(), "/.well-known/agent-skills/index.json"),
          get(build_conn(), "/metadata/1/1")
        ] do
      assert json_response(conn, 503) == refused("not_open_yet"), conn.request_path
      assert get_resp_header(conn, "retry-after") == ["3600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "while closed, the agent guides, the directory and the contract answer one plain 503 line" do
    close_surfaces()

    for conn <- [
          get(build_conn(), "/skill.md"),
          get(build_conn(), "/.well-known/agent-skills/keyfleet/SKILL.md"),
          get(build_conn(), "/.well-known/agent-skills/keyfleet.zip"),
          get(build_conn(), "/llms.txt"),
          get(build_conn(), "/fleets.md"),
          get(build_conn(), "/fleets/fibonacci_syndicate.md"),
          get(build_conn(), "/api-contract.openapiv3.yaml"),
          build_conn() |> put_req_header("accept", "text/markdown") |> get("/"),
          build_conn() |> put_req_header("accept", "text/markdown") |> get("/opportunities")
        ] do
      assert response(conn, 503) == @closed_message <> "\n", conn.request_path
      assert response_content_type(conn, :md) =~ "text/markdown"
      assert get_resp_header(conn, "retry-after") == ["3600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "closed answers carry the strict reading policy and the open page's other headers" do
    open = get(build_conn(), "/account")
    close_surfaces()

    for closed <- [get(build_conn(), "/auth/session"), get(build_conn(), "/fleets.md")] do
      assert get_resp_header(closed, "content-security-policy") ==
               [ContentSecurityPolicy.reading()]

      assert secure_headers(closed) == secure_headers(open)
    end

    assert get_resp_header(open, "content-security-policy") == [ContentSecurityPolicy.sign_in()]
    assert secure_headers(open) != %{}
  end

  test "while closed, the early-access page, the operational files and the static files stay open" do
    close_surfaces()

    for path <-
          ~w(/early /healthz /robots.txt /.well-known/security.txt) ++
            ~w(/sitemap.xml /favicon.ico /favicon-32.png /mark.png /images/brand/mark-flat-dark.svg /metadata/collection.json) do
      assert get(build_conn(), path).status == 200, "#{path} closed"
    end

    assert json_response(get(build_conn(), "/metadata/keys/50000000001"), 404) ==
             refused("key_not_found")

    assert json_response(post(build_conn(), "/metadata/collection.json", %{}), 503) ==
             refused("not_open_yet")

    assert get(build_conn(), "/healthz").resp_body == "ok"
  end

  test "while closed, the reading pages stay open inside the shell, as pages and as Markdown" do
    close_surfaces()
    {signed_in, _account} = signed_in()

    for path <- @reading, conn <- [build_conn(), signed_in] do
      page = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
      assert Enum.count(LazyHTML.query(page, "#app-shell #route-content .reading__prose")) == 1
      assert Enum.count(LazyHTML.query(page, "#app-shell-scroller > footer.regent-footer")) == 1

      # Each is headed by its document's title; the developer documentation by Docs.
      "# " <> document = PublicDocuments.document(path).markdown
      [title | _rest] = String.split(document, "\n", parts: 2)
      heading = page |> LazyHTML.query("#route-content h1") |> LazyHTML.text()
      assert heading == if(path == "/docs", do: "Docs", else: title), path

      markdown = build_conn() |> put_req_header("accept", "text/markdown") |> get(path)
      assert response(markdown, 200) |> String.starts_with?("# " <> title), path
      assert response_content_type(markdown, :md) =~ "text/markdown"
    end

    # Over the socket too, signed out and signed in.
    for conn <- [build_conn(), signed_in] do
      assert {:ok, _view, _html} = live(conn, "/privacy")
    end
  end

  test "while closed, the sitemap lists only the pages still open" do
    close_surfaces()

    assert locations(get(build_conn(), "/sitemap.xml")) ==
             Enum.map(
               ~w(/early /agents /docs /changelog /about /privacy /terms),
               &PublicDocuments.url/1
             )

    open_surfaces()

    assert PublicDocuments.url("/early") not in locations(get(build_conn(), "/sitemap.xml"))
  end

  test "while open, the homepage is itself and the early-access page and its form send visitors to it" do
    home = get(build_conn(), "/")

    title =
      home.resp_body
      |> LazyHTML.from_document()
      |> LazyHTML.query("h1#home-title")
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

    assert home.status == 200
    assert title == "A persistent team for your AI agent."

    for early <- [
          get(build_conn(), "/early"),
          post(build_conn(), "/early", %{"email" => "ada@example.com"})
        ] do
      assert redirected_to(early, 302) == "/"
      assert get_resp_header(early, "cache-control") == ["no-store"]
    end
  end

  test "a mount arriving over the socket is sent to the early-access page instead" do
    close_surfaces()

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, live_action: :account}}

    assert {:halt, halted} = LaunchGateHook.on_mount(:default, %{}, %{}, socket)

    assert halted.redirected == {:redirect, %{to: "/early", status: 302}}
  end

  test "a page open when the site closes cannot keep browsing product routes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/account")

    close_surfaces()

    # A reading page is open either way.
    assert render_patch(view, "/docs") =~ "reading__prose"

    render_patch(view, "/syndicate/1")
    assert_redirect(view, "/early")
  end

  defp signed_in do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    account =
      Accounts.register_verified!("did:privy:launch-gate-" <> wallet, wallet, [wallet],
        actor: %Keyfleet.Actors.System{}
      )

    {init_test_session(build_conn(), %{human_account_id: account.id}), account}
  end

  defp locations(conn) do
    ~r{<loc>([^<]+)</loc>}
    |> Regex.scan(response(conn, 200), capture: :all_but_first)
    |> List.flatten()
  end

  # Reads the file a boot reads, returning its settings and the log it wrote.
  defp read_runtime_config(env) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log(fn -> Config.Reader.read!("config/runtime.exs", env: env) end)
    after
      Logger.configure(level: level)
    end
  end

  defp restore_setting(nil), do: System.delete_env("KEYFLEET_APP_SURFACES")
  defp restore_setting(setting), do: System.put_env("KEYFLEET_APP_SURFACES", setting)

  defp secure_headers(conn) do
    conn.resp_headers
    |> Map.new()
    |> Map.take(~w(referrer-policy x-content-type-options x-permitted-cross-domain-policies
       x-frame-options))
  end
end
