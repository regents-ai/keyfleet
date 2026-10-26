defmodule KeyfleetWeb.FleetNow do
  @moduledoc """
  What each fleet is doing right now, as a signed-out visitor reads it, read
  once for every open page and held in `Keyfleet.SharedReading`. One runs on
  each machine.

  A fleet's reading holds whether it is coming soon and, once it is open:

    * `deployed?`, `current?` and `minted`: how far it has sold, as far as its
      Key history has been read (`Keyfleet.Chain.minted/2`, `fresh?/1`);
    * `feed`: the first page of its activity with no actor
      (`Keyfleet.Activity.page/3`), its items and the cursor for the page
      after them;
    * `trying`: "Trying now", each of its projects by title with the titles
      of its open goals (`KeyfleetWeb.FleetPage.read_trying_now/1`);
    * `goal`: the title of its most recently changed open goal, and
      `headline`: the item it features (`Keyfleet.Activity.headline/2`), which
      the homepage shows.

  Pages showing a fleet to a reader who isn't a member draw it from here: the
  homepage, the fleet hall and the harbour's sea; the header's "Purchase Key"
  reads from it whether its fleet is open. A member's reading differs
  (rooms other than the Public room, the workspace's changes), so a member's
  page still reads under its own scope.

  This is a reread on notice, the second of the two shapes the `elixir-stack`
  skill lets keep a shared reading. It hears what an open page of a fleet hears
  as a non-member: the fleet's Keys, its public rooms, its notable workspace
  changes and its proposals. A burst of notices is answered by one read of
  each fleet named, a second after the first. Each minute
  `Keyfleet.SharedReading.Heal` asks for every fleet again, which mends a lost
  notice and brings in a fleet's record when it opens; a coming-soon fleet
  costs that one read. It holds nothing but which fleets are due a read, and
  it never writes the database.

  Before, every open page read its fleet itself, all of them after the same
  notice, so a crowd cost the database a read each in the same instant, and
  every page that reconnected after a deploy read again. Now a crowd costs
  what one visitor costs (`ash-frontend`, `references/public-figures.md`).

  The first read happens as it starts, with a bounded wait, so each fleet
  holds a reading or its degraded mark before the site serves a page, and a
  database that doesn't answer never holds up the start.
  """

  use GenServer

  alias Keyfleet.{Activity, Chain, Fleets, Graph, Keys, Proposals, Rooms, SharedReading}
  alias KeyfleetWeb.{FleetPage, PageRead}
  alias Phoenix.Socket.Broadcast

  @doc "Where the reading of `fleet_id` is held."
  def key(fleet_id), do: {:fleet_now, fleet_id}

  @doc "The reading held for `fleet_id`, and whether its last read failed; nil while there is none."
  def fetch(fleet_id) do
    case SharedReading.fetch(key(fleet_id)) do
      {:ok, %{reading: %{} = reading, degraded?: degraded?}} -> {reading, degraded?}
      _not_read -> nil
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(:fleet_now)

    # By topic, so a room's head, which names no fleet, is still a fleet's.
    topics =
      for fleet_id <- Fleets.catalog_ids(),
          topic <- [
            Keys.topic(fleet_id),
            Rooms.topic(fleet_id, :public),
            Graph.notable_topic(fleet_id),
            Proposals.topic(fleet_id)
          ],
          into: %{},
          do: {topic, fleet_id}

    Enum.each(Map.keys(topics), &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    first_read(Fleets.catalog_ids())
    {:ok, %{due: MapSet.new(), topics: topics}}
  end

  # Every fleet is read beside the start, all at once, so a slow database holds
  # the start for one wait, not one per fleet. Any not read in time is marked
  # degraded; its next notice or the minute's heal reads it again.
  defp first_read(fleet_ids) do
    fleet_ids
    |> Task.async_stream(&__MODULE__.read/1,
      max_concurrency: length(fleet_ids),
      timeout: Application.fetch_env!(:keyfleet, :first_read_ms),
      on_timeout: :kill_task
    )
    |> Enum.zip(fleet_ids)
    |> Enum.each(fn
      {{:ok, _read}, _fleet_id} -> :ok
      {{:exit, :timeout}, fleet_id} -> SharedReading.degraded(key(fleet_id))
    end)
  end

  @impl true
  def handle_info(%Broadcast{topic: topic}, state),
    do: {:noreply, due(state, state.topics[topic])}

  def handle_info({:graph_notable, fleet_id}, state), do: {:noreply, due(state, fleet_id)}

  def handle_info({:keys_changed, fleet_id, _token_ids}, state),
    do: {:noreply, due(state, fleet_id)}

  def handle_info({:proposals_changed, fleet_id}, state), do: {:noreply, due(state, fleet_id)}

  # Balances aren't in the reading.
  def handle_info({:balances_changed, _fleet_id}, state), do: {:noreply, state}

  def handle_info({:shared_reading_heal, :fleet_now}, state),
    do: {:noreply, Enum.reduce(Fleets.catalog_ids(), state, &due(&2, &1))}

  def handle_info(:read, state) do
    Enum.each(state.due, &__MODULE__.read/1)
    {:noreply, %{state | due: MapSet.new()}}
  end

  # The first fleet to fall due starts the one-second wait; the rest join it.
  defp due(state, fleet_id) do
    if MapSet.size(state.due) == 0, do: Process.send_after(self(), :read, 1_000)
    %{state | due: MapSet.put(state.due, fleet_id)}
  end

  @doc "Reads `fleet_id` and puts its reading. What the producer runs on each pass."
  def read(fleet_id) do
    case reading(fleet_id, DateTime.utc_now()) do
      {:ok, reading} -> SharedReading.put(key(fleet_id), reading)
      {:error, _not_read} -> SharedReading.degraded(key(fleet_id))
    end
  end

  # A failed database read is a read not taken, never a reason for this
  # process, and the site with it, to stop. It is logged and saved with the
  # site's errors as a page's own read is (`KeyfleetWeb.PageRead`), so one that
  # keeps failing is seen at /admin/errors.
  defp reading(fleet_id, now) do
    PageRead.run("fleet", fn ->
      recorded = Map.new(Fleets.list_fleets!(), &{&1.id, &1})[fleet_id]

      if Fleets.coming_soon?(fleet_id, recorded),
        do: %{coming_soon?: true},
        else: open(fleet_id, recorded, now)
    end)
  end

  defp open(fleet_id, recorded, now) do
    deployed? = recorded != nil and recorded.manager_address != nil
    %{items: items, cursor: cursor} = Activity.page(fleet_id, nil)

    %{
      coming_soon?: false,
      deployed?: deployed?,
      chain_id: if(deployed?, do: recorded.chain_id),
      current?: deployed? and Chain.fresh?(fleet_id),
      minted: if(deployed?, do: minted!(fleet_id), else: 0),
      feed: %{items: items, cursor: cursor},
      trying: FleetPage.read_trying_now(fleet_id),
      goal: goal(fleet_id),
      headline: Activity.headline(fleet_id, now)
    }
  end

  defp minted!(fleet_id) do
    case Chain.minted(fleet_id) do
      {:ok, minted} -> minted
      {:error, failure} -> raise failure
    end
  end

  defp goal(fleet_id) do
    case Graph.open_goals!(fleet_id, query: [limit: 1]) do
      [goal] -> goal.title
      [] -> nil
    end
  end
end
