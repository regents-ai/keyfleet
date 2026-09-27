defmodule KeyfleetWeb.LaunchGateTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias KeyfleetWeb.ContentSecurityPolicy
  alias KeyfleetWeb.Live.LaunchGateHook
  alias KeyfleetWeb.Plugs.LaunchGate

  @gated_shell_paths ~w(/account /app/fleets/fibonacci_syndicate)
  @closed_message "This part of the site isn't open yet."

  setup do
    on_exit(&open_surfaces/0)

    :ok
  end

  defp close_surfaces, do: Application.put_env(:keyfleet, :app_surfaces, false)
  defp open_surfaces, do: Application.put_env(:keyfleet, :app_surfaces, true)

  test "one switch is open by default and reads both explicit states" do
    Application.delete_env(:keyfleet, :app_surfaces)
    assert LaunchGate.app_surfaces_enabled?()

    open_surfaces()
    assert LaunchGate.app_surfaces_enabled?()

    close_surfaces()
    refute LaunchGate.app_surfaces_enabled?()
  end

  test "the switch takes effect between requests of one running build" do
    assert get(build_conn(), "/account").status == 200

    close_surfaces()
    assert get(build_conn(), "/account").status == 503

    open_surfaces()
    assert get(build_conn(), "/account").status == 200
  end

  test "production refuses to boot without an explicit setting, and records the state" do
    original = System.get_env("KEYFLEET_APP_SURFACES")
    on_exit(fn -> restore_setting(original) end)
    System.delete_env("KEYFLEET_APP_SURFACES")

    assert_raise RuntimeError, ~s(KEYFLEET_APP_SURFACES must be set to "on" or "off"), fn ->
      read_runtime_config(:prod)
    end

    assert {config, log} = read_runtime_config(:test)
    assert config[:keyfleet][:app_surfaces]
    assert log =~ "App surfaces enabled"

    System.put_env("KEYFLEET_APP_SURFACES", "yes")

    assert {config, log} = read_runtime_config(:test)
    refute config[:keyfleet][:app_surfaces]
    assert log =~ "App surfaces disabled"
  end

  test "every product route answers 503 with no product markup and no caching" do
    close_surfaces()

    for path <- @gated_shell_paths do
      conn = get(build_conn(), path)

      assert conn.status == 503, "#{path} stayed open"
      assert get_resp_header(conn, "retry-after") == ["3600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ ~s(id="app-shell")
    end
  end

  test "closed answers carry the strict reading policy and the open page's other headers" do
    open = get(build_conn(), "/account")
    close_surfaces()

    for closed <- [
          get(build_conn(), "/account"),
          get(build_conn(), "/auth/session"),
          get(build_conn(), "/fleets.md")
        ] do
      assert get_resp_header(closed, "content-security-policy") ==
               [ContentSecurityPolicy.reading()]

      assert secure_headers(closed) == secure_headers(open)
    end

    assert get_resp_header(open, "content-security-policy") == [ContentSecurityPolicy.sign_in()]
    assert secure_headers(open) != %{}
  end

  test "session and API JSON endpoints answer one plain 503 line" do
    close_surfaces()

    for conn <- [
          get(build_conn(), "/api/v1/profile"),
          get(build_conn(), "/auth/session")
        ] do
      assert json_response(conn, 503) == %{"error" => @closed_message}
      assert get_resp_header(conn, "retry-after") == ["3600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "the fleet directory's Markdown answers one plain 503 line" do
    close_surfaces()

    for path <- ["/fleets.md", "/fleets/fibonacci_syndicate.md"] do
      conn = get(build_conn(), path)

      assert response(conn, 503) == @closed_message <> "\n"
      assert response_content_type(conn, :md) =~ "text/markdown"
      assert get_resp_header(conn, "retry-after") == ["3600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "the marketing page, health check and static files are untouched by the gate" do
    close_surfaces()
    home = get(build_conn(), "/")

    title =
      home.resp_body
      |> LazyHTML.from_document()
      |> LazyHTML.query("h1#home-title")
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

    assert home.status == 200
    assert title == "Your agent has tools. Now give it a crew."
    refute home.resp_body =~ "Not open yet"

    assert get(build_conn(), "/healthz").status == 200
    assert get(build_conn(), "/healthz").resp_body == "ok"
    assert get(build_conn(), "/robots.txt").status == 200
    assert get(build_conn(), "/privacy").status == 200
    assert get(build_conn(), "/terms").status == 200
  end

  test "signing out stays available while every other session endpoint closes" do
    close_surfaces()

    assert json_response(delete(build_conn(), "/auth/privy/session"), 200) == %{"ok" => true}
    assert json_response(get(build_conn(), "/auth/csrf"), 503) == %{"error" => @closed_message}

    assert json_response(post(build_conn(), "/auth/privy/session", %{}), 503) ==
             %{"error" => @closed_message}
  end

  test "a mount arriving over the socket is sent to the marketing page instead" do
    close_surfaces()

    assert {:halt, halted} =
             LaunchGateHook.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})

    assert halted.redirected == {:redirect, %{to: "/", status: 302}}
  end

  test "a page open when the gate closes cannot keep browsing product routes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/account")

    close_surfaces()
    render_patch(view, "/app/fleets/fibonacci_syndicate")

    assert_redirect(view, "/")
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
