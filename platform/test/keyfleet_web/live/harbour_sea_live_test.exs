defmodule KeyfleetWeb.HarbourSeaLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{ChainHelpers, Fleets, Graph, Keys, Proposals, Rooms}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{FleetNow, HarbourSeaLive}

  # Invariants covered:
  # - every page's sea is Classic #1's, the Club's pages included, drawn for a
  #   signed-out visitor from Classic's shared reading, and an open sea
  #   redraws when that reading is read again
  # - the inn, the forge and the castle open Classic #1's General room,
  #   workspace and proposals
  # - showing the fleet and hearing its new reading cost a signed-out visitor's
  #   sea no database read, and it hears none of the fleet's own notices, so a
  #   crowd of open pages doesn't read the fleet again on each of them

  @classic "fleet_tech_classic"
  @club "regents_club"

  setup do
    Fleets.bootstrap_catalog!()

    for fleet_id <- [@classic, @club] do
      ChainHelpers.deploy!(fleet_id)
      ChainHelpers.seed_cursor!(fleet_id)
      Workspace.open_log(fleet_id)
      # What the producer does as the site starts; producers don't run here.
      FleetNow.read(fleet_id)
    end

    :ok
  end

  test "every page's sea is Classic #1's, drawn from its shared reading and drawn again",
       %{conn: conn} do
    view = sea(conn)
    show(view, "/app/fleets/regents_club")
    assert crew(view) == []

    goal(@club, 18)
    FleetNow.read(@club)
    goal(@classic, 17)
    assert crew(view) == []

    FleetNow.read(@classic)
    assert [%{"id" => "fleet_tech_classic:17", "place" => "forge"}] = crew(view)

    show(view, "/about")
    assert [%{"id" => "fleet_tech_classic:17"}] = crew(view)
  end

  test "the inn, the forge and the castle open Classic #1's General room, workspace and proposals",
       %{conn: conn} do
    assert %{
             "inn" => %{"name" => "General chat", "href" => "/classic/1/rooms/general"},
             "forge" => %{"name" => "Workspace", "href" => "/classic/1/workspace"},
             "castle" => %{"name" => "Proposals", "href" => "/classic/1/proposals"}
           } == conn |> sea() |> attribute("data-harbour-places")
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

    show(view, "/classic/1")
    goal(@classic, 17)
    FleetNow.read(@classic)
    assert [%{"id" => "fleet_tech_classic:17"}] = crew(view)
    refute_received :sea_query

    heard = Registry.keys(Keyfleet.PubSub, pid)

    for topic <- [
          Rooms.topic(@classic, :public),
          Graph.topic(@classic, :public),
          Proposals.topic(@classic),
          Keys.topic(@classic)
        ],
        do: refute(topic in heard)
  end

  # The sea of a signed-out visitor, as the root layout renders it.
  defp sea(conn) do
    {:ok, view, _html} = live_isolated(conn, HarbourSeaLive, session: %{"render_route" => "/"})
    view
  end

  # What the page tells the sea when a page is on show.
  defp show(view, path), do: render_hook(view, "show_page", %{"path" => path})

  # A goal a Key makes, which sails its ship to the forge.
  defp goal(fleet_id, key) do
    data = %{"title" => "Sell the first audit", "outcome" => "O"}
    Workspace.create(fleet_id, "goal", data, by: key)
  end

  # The ships the sea hands its hook.
  defp crew(view), do: attribute(view, "data-harbour-crew")

  defp attribute(view, name) do
    view
    |> element("#harbour")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
    |> Jason.decode!()
  end
end
