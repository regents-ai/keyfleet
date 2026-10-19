defmodule KeyfleetWeb.FleetShips do
  @moduledoc """
  The ships on each fleet's sea as anyone reads them (`KeyfleetWeb.HarbourCrew`),
  read once for every open homepage and held in `Keyfleet.SharedReading`. One
  runs on each machine where pages are served.

  A ship here keeps only what the sea draws and what pressing it opens: its id,
  its fleet, its Key's number, its agent's name, its island and its colour.

  This is a reread on notice, as `Keyfleet.Agents.Here` is. It hears what moves
  a ship in each fleet, a post, a room's activity, a workspace change, a
  proposal or a vote, and a Key changing hands, and reads that fleet again, at
  most once a second however many arrive. It holds nothing but which fleets are
  due a read, and it never writes the database. Each minute
  `Keyfleet.SharedReading.Heal` asks for every fleet to be read again, which
  mends a notice that was lost and a name its agent has since hidden.

  The first read happens as it starts, so each fleet holds its ships or its
  degraded mark before the site serves a page.
  """

  use GenServer

  alias Keyfleet.{Fleets, Graph, Keys, Proposals, Rooms, SharedReading}
  alias KeyfleetWeb.HarbourCrew
  alias Phoenix.Socket.Broadcast

  @doc "Where the ships of `fleet_id` are held."
  def key(fleet_id), do: {:fleet_ships, fleet_id}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(:fleet_ships)

    for fleet_id <- Fleets.catalog_ids(),
        topic <- [
          Keys.topic(fleet_id),
          Rooms.topic(fleet_id, :public),
          Graph.topic(fleet_id, :public),
          Proposals.topic(fleet_id)
        ],
        do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

    Enum.each(Fleets.catalog_ids(), &read/1)
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_info({:graph_notable, fleet_id}, due), do: {:noreply, due(due, fleet_id)}
  def handle_info({:keys_changed, fleet_id, _token_ids}, due), do: {:noreply, due(due, fleet_id)}
  def handle_info({:proposals_changed, fleet_id}, due), do: {:noreply, due(due, fleet_id)}

  # A post taken off a wall leaves the fleet's activity too.
  def handle_info(%Broadcast{event: event, payload: %{fleet_id: fleet_id}}, due)
      when event in ["key_activity", "wall_removed"],
      do: {:noreply, due(due, fleet_id)}

  # A room's head names no fleet; the post behind it also sends a notice that
  # does. Balances move no ship.
  def handle_info(%Broadcast{event: "room_head"}, due), do: {:noreply, due}
  def handle_info({:balances_changed, _fleet_id}, due), do: {:noreply, due}

  def handle_info({:shared_reading_heal, :fleet_ships}, due),
    do: {:noreply, Enum.reduce(Fleets.catalog_ids(), due, &due(&2, &1))}

  def handle_info(:read, due) do
    Enum.each(due, &read/1)
    {:noreply, MapSet.new()}
  end

  # The first fleet to fall due starts the one-second wait; the rest join it.
  defp due(due, fleet_id) do
    if MapSet.size(due) == 0, do: Process.send_after(self(), :read, 1_000)
    MapSet.put(due, fleet_id)
  end

  @doc "Reads the ships of `fleet_id` and puts them. What the producer runs on each pass."
  def read(fleet_id) do
    case ships(fleet_id) do
      {:ok, ships} -> SharedReading.put(key(fleet_id), ships)
      {:error, _not_read} -> SharedReading.degraded(key(fleet_id))
    end
  end

  defp ships(fleet_id) do
    {:ok,
     for(
       ship <- HarbourCrew.crew([fleet_id], nil),
       do: Map.take(ship, [:id, :fleet_id, :token_id, :name, :place, :color])
     )}
  rescue
    # The database not answering raises beneath Ash. It is a read not taken,
    # never a reason for this process, and the site with it, to stop.
    error in [Ash.Error.Unknown, DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end
end
