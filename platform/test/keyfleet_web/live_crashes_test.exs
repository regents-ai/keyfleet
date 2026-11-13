defmodule KeyfleetWeb.LiveCrashesTest do
  # A live page that fails keeps the browser's session, and what the page holds,
  # out of the log and out of the saved error (`KeyfleetWeb.LiveCrashes`). On
  # 13 Nov one such crash printed the whole session, its form token and live
  # socket id included, into the lines Fly and Sentinel keep.
  use KeyfleetWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  defmodule RaisingLive do
    use KeyfleetWeb, :live_view

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: raise("the page failed as it connected"), else: {:ok, socket}
    end

    @impl true
    def render(assigns), do: ~H"<p>page</p>"
  end

  defmodule UnmatchedLive do
    use KeyfleetWeb, :live_view

    # Once connected it takes only a session with a client key, so the stack's
    # first line carries the session it was given.
    @impl true
    def mount(_params, _session, %{transport_pid: nil} = socket), do: {:ok, socket}
    def mount(_params, %{"client_key" => _key}, socket), do: {:ok, socket}

    @impl true
    def render(assigns), do: ~H"<p>page</p>"
  end

  defmodule PressLive do
    use KeyfleetWeb, :live_view

    @impl true
    def mount(_params, _session, socket),
      do: {:ok, assign(socket, code_password: %{password: "git-password-marker-51e0"})}

    # A press without `known` matches no head, so the stack's first line carries
    # the socket and every assign on it.
    @impl true
    def handle_event("press", %{"known" => _known}, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <button phx-click="press">Press</button>
      """
    end
  end

  @session %{
    "_csrf_token" => "form-token-marker-7c1e",
    "live_socket_id" => "session_authority:socket-marker-4d2b",
    "session_lineage" => "lineage-marker-9a3f",
    "session_generation" => 0
  }

  for {failure, view, exception} <- [
        {"raises", RaisingLive, RuntimeError},
        {"matches none of its mount heads", UnmatchedLive, FunctionClauseError}
      ] do
    @view view
    @exception exception

    test "a page that #{failure} as it connects names the failure and none of the session", %{
      conn: conn
    } do
      log = capture_log(fn -> catch_exit(live_isolated(with_session(conn), @view)) end)

      assert_named_without(log, @view, @exception, [
        @session["_csrf_token"],
        @session["live_socket_id"],
        @session["session_lineage"]
      ])
    end
  end

  test "a page whose press matches no head names the failure and none of what it holds", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(with_session(conn), PressLive)

    # The open page is linked to this test, which outlives it.
    Process.flag(:trap_exit, true)
    log = capture_log(fn -> catch_exit(render_click(view, "press", %{})) end)

    assert_named_without(log, PressLive, FunctionClauseError, [
      "git-password-marker-51e0",
      @session["session_lineage"]
    ])
  end

  defp with_session(conn) do
    conn
    |> connects_with(@session)
    |> put_connect_params(%{"_csrf_token" => @session["_csrf_token"]})
  end

  defp assert_named_without(log, view, exception, markers) do
    # The saved errors are ErrorTracker's own tables, not Ash records.
    saved =
      Keyfleet.Repo.all(
        from(error in ErrorTracker.Error,
          join: occurrence in assoc(error, :occurrences),
          where: fragment("?->>'live_view.view'", occurrence.context) == ^to_string(view),
          select: {error, occurrence}
        )
      )

    assert log =~ inspect(exception)
    assert [{%{kind: kind}, _occurrence}] = saved
    assert kind == to_string(exception)

    for marker <- markers do
      refute log =~ marker
      refute inspect(saved, limit: :infinity, printable_limit: :infinity) =~ marker
    end
  end
end
