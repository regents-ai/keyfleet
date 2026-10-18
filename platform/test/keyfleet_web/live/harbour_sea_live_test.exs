defmodule KeyfleetWeb.HarbourSeaLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{ChainHelpers, Fleets, Graph, Keys, Proposals, Rooms}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{FleetNow, HarbourSeaLive}

  # Invariants covered:
  # - a signed-out visitor's sea draws a fleet's ships from the fleet's shared
  #   reading, and an open sea redraws when that reading is read again
  # - showing a fleet and hearing its new reading cost a signed-out visitor's
  #   sea no database read, and it hears none of the fleet's own notices, so a
  #   crowd of open pages doesn't read the fleet again on each of them

  @club "regents_club"

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@club)
    ChainHelpers.seed_cursor!(@club)
    Workspace.open_log(@club)
    # What the producer does as the site starts; producers don't run here.
    FleetNow.read(@club)
    :ok
  end

  test "a signed-out sea draws its fleet from the shared reading, and draws it again",
       %{conn: conn} do
    view = sea(conn)
    show_club(view)
    assert crew(view) == []

    goal()
    assert crew(view) == []

    FleetNow.read(@club)
    assert [%{"id" => "regents_club:17", "place" => "forge"}] = crew(view)
  end

  test "a signed-out sea reads nothing itself and hears none of the fleet's notices",
       %{conn: conn} do
    view = sea(conn)
    pid = view.pid
    handler = "harbour-queries-#{System.unique_integer([:positive])}"
    test_pid = self()

    # Queries the sea makes, in its own process or a read it started.
    :telemetry.attach(
      handler,
      [:keyfleet, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if pid in [self() | Process.get(:"$callers", [])], do: send(test_pid, :sea_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    show_club(view)
    goal()
    FleetNow.read(@club)
    assert [%{"id" => "regents_club:17"}] = crew(view)
    refute_received :sea_query

    heard = Registry.keys(Keyfleet.PubSub, pid)

    for topic <- [
          Rooms.topic(@club, :public),
          Graph.topic(@club, :public),
          Proposals.topic(@club),
          Keys.topic(@club)
        ],
        do: refute(topic in heard)
  end

  # The sea of a signed-out visitor, as the root layout renders it.
  defp sea(conn) do
    {:ok, view, _html} = live_isolated(conn, HarbourSeaLive, session: %{"render_route" => "/"})
    view
  end

  # What the page tells the sea when the Club's page is on show.
  defp show_club(view),
    do: render_hook(view, "show_page", %{"path" => "/app/fleets/regents_club"})

  # A goal Key 17 makes, which sails its ship to the forge.
  defp goal do
    data = %{"title" => "Sell the first audit", "outcome" => "O"}
    Workspace.create(@club, "goal", data, by: 17)
  end

  # The ships the sea hands its hook.
  defp crew(view) do
    view
    |> element("#harbour")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-harbour-crew")
    |> hd()
    |> Jason.decode!()
  end
end
