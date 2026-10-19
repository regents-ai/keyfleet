defmodule KeyfleetWeb.FleetShipsTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{ChainHelpers, Fleets, SharedReading}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.FleetShips

  # Invariants covered:
  # - a read puts the fleet's ships as anyone reads them, each keeping only
  #   what the sea draws and what pressing it opens
  # - the fullest reading the kind can be handed fits its size
  # - a post taken off a wall reads its fleet again

  @club "regents_club"

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@club)
    ChainHelpers.seed_cursor!(@club)
    Workspace.open_log(@club)
    on_exit(fn -> SharedReading.delete(FleetShips.key(@club)) end)
    :ok
  end

  test "a read puts the fleet's ships, each with only what the sea needs" do
    Workspace.create(@club, "goal", %{"title" => "Ship the site", "outcome" => "O"}, by: 17)

    assert :ok = FleetShips.read(@club)

    assert {:ok, %{reading: [ship], degraded?: false}} =
             SharedReading.fetch(FleetShips.key(@club))

    assert %{id: "regents_club:17", fleet_id: @club, token_id: 17, place: "forge"} = ship
    assert Map.keys(ship) |> Enum.sort() == [:color, :fleet_id, :id, :name, :place, :token_id]
  end

  # R-20261019-wall-removal-reads-again: a post taken off a wall stopped the
  # process, and a few in a row the site with it.
  test "a post taken off a wall reads its fleet again" do
    pid = start_supervised!(FleetShips)

    send(pid, %Phoenix.Socket.Broadcast{
      event: "wall_removed",
      payload: %{fleet_id: @club, token_id: 17, message_id: Ecto.UUID.generate()}
    })

    assert :sys.get_state(pid) == MapSet.new([@club])
  end

  test "the fullest reading fits the kind" do
    # Sixteen ships of the fleet with the longest id, each named with the most
    # an agent's name may hold, in characters four bytes long.
    fleet_id = Enum.max_by(Fleets.catalog_ids(), &byte_size/1)
    name = String.duplicate("𝕂", 120)

    ships =
      for token_id <- 1_009..1_024,
          do: %{
            id: "#{fleet_id}:#{token_id}",
            fleet_id: fleet_id,
            token_id: token_id,
            name: name,
            place: "castle",
            color: "#2e86de"
          }

    assert :ok = SharedReading.put(FleetShips.key(@club), ships)
  end
end
