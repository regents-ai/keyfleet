defmodule KeyfleetWeb.FleetPolls do
  @moduledoc """
  Each fleet's polls as a signed-out visitor reads them, read once for every
  open page and held in `Keyfleet.SharedReading`. One runs on each machine.

  Two kinds of reading come from each pass over a fleet:

    * `key/1`: the fleet's name, whether it is on chain, and its latest
      hundred polls as the polls page lists them (`Keyfleet.Polls.list_polls/2`
      with no actor);
    * `poll_key/2`: each of those polls as its own page shows it, with its
      choices.

  Each poll is what `KeyfleetWeb.PollsLive.public/2` keeps of it: its
  question, choices, starter's Key, times, how many votes it has drawn,
  whether it is still open and, once closed, each choice's count. Anyone may
  read all of it (`Keyfleet.Polls.Poll`'s read policies). A poll's notes and
  each Key's vote are for the fleet's Key holders only, so they are never
  here: a holder's page reads them as that holder.

  This is a reread on notice, the second of the two shapes the
  `elixir-stack` skill lets keep a shared reading. It hears every poll
  started or ended in the fleets (`Keyfleet.Polls.fleet_topic/1`) and every
  vote on each poll that is open (`Keyfleet.Polls.topic/1`), and answers a
  burst of them with one read of each fleet named, a second after the first.
  A poll closing at its time sends no notice, so the producer keeps one
  timer for each fleet, at the moment its next open poll closes, and reads
  the fleet then, so its result comes to every page about a second later.
  Each minute `Keyfleet.SharedReading.Heal` asks for every fleet again, which
  mends a lost notice. It holds which fleets are due a read, which polls it
  hears and when each fleet's next poll closes, and it never writes the
  database.

  Before, every open page of a poll read it again on each vote and drew its
  countdown again every second; now a crowd costs what one visitor costs, and
  the countdown is drawn in the browser (`assets/js/hooks/poll_countdown.ts`).

  The first read happens as it starts, with a bounded wait, so each fleet
  holds a reading or its degraded mark before the site serves a page.
  """

  use GenServer

  alias Keyfleet.{Fleets, Polls, SharedReading}
  alias KeyfleetWeb.{PageRead, PollsLive}
  alias Phoenix.Socket.Broadcast

  # The longest the first read of every fleet may take as the site starts.
  @first_read 5_000
  # A poll is read this long after its closing time, so it has its result.
  @after_close 50

  @kinds [:fleet_polls, :poll]

  @doc "Where `fleet_id`'s polls are held."
  def key(fleet_id), do: {:fleet_polls, fleet_id}

  @doc """
  Where one poll's page is held. `poll_id` is one the fleet's reading holds,
  never one taken from an address.
  """
  def poll_key(fleet_id, poll_id), do: {:poll, "#{fleet_id}:#{poll_id}"}

  @doc "The reading held at `key`, and whether its last read failed; nil while there is none."
  def fetch(key) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: %{} = reading, degraded?: degraded?}} -> {reading, degraded?}
      _not_read -> nil
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    Enum.each(@kinds, &SharedReading.subscribe_heal/1)

    topics = Map.new(Fleets.catalog_ids(), &{Polls.fleet_topic(&1), &1})
    Enum.each(Map.keys(topics), &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    first_read(Fleets.catalog_ids())

    state = %{due: MapSet.new(), topics: topics, closing: %{}}
    {:ok, Enum.reduce(Fleets.catalog_ids(), state, &follow(&2, &1))}
  end

  # Every fleet is read beside the start, and any not read in time is marked
  # degraded; its next notice or the minute's heal reads it again.
  defp first_read(fleet_ids) do
    fleet_ids
    |> Task.async_stream(&__MODULE__.read/1, timeout: @first_read, on_timeout: :kill_task)
    |> Enum.zip(fleet_ids)
    |> Enum.each(fn
      {{:ok, _read}, _fleet_id} -> :ok
      {{:exit, :timeout}, fleet_id} -> degraded(fleet_id)
    end)
  end

  # A poll started or ended, or a vote. One from a poll no longer heard,
  # sent before it stopped being heard, changes nothing.
  @impl true
  def handle_info(%Broadcast{topic: topic}, state) do
    case state.topics do
      %{^topic => fleet_id} -> {:noreply, due(state, fleet_id)}
      _not_heard -> {:noreply, state}
    end
  end

  def handle_info({:closes, fleet_id}, state),
    do: {:noreply, due(%{state | closing: Map.delete(state.closing, fleet_id)}, fleet_id)}

  # The two kinds' heals arrive together each minute and join one pass.
  def handle_info({:shared_reading_heal, _kind}, state),
    do: {:noreply, Enum.reduce(Fleets.catalog_ids(), state, &due(&2, &1))}

  def handle_info(:read, %{due: due} = state) do
    Enum.each(due, &__MODULE__.read/1)
    {:noreply, Enum.reduce(due, %{state | due: MapSet.new()}, &follow(&2, &1))}
  end

  # The first fleet to fall due starts the one-second wait; the rest join it.
  defp due(state, fleet_id) do
    if MapSet.size(state.due) == 0, do: Process.send_after(self(), :read, 1_000)
    %{state | due: MapSet.put(state.due, fleet_id)}
  end

  # After a pass, the producer hears the votes on each of the fleet's open
  # polls and no others, and its timer waits for the next of them to close.
  # A poll first heard now may have drawn a vote between the read and the
  # listening, so the fleet is read once more. After a read that failed it
  # keeps hearing what it heard and sets no timer, so a database that
  # doesn't answer is asked again by the next notice or the minute's heal,
  # never by a timer of its own.
  defp follow(state, fleet_id) do
    {open, read?} =
      case fetch(key(fleet_id)) do
        {%{polls: polls}, degraded?} -> {Enum.filter(polls, & &1.open?), not degraded?}
        nil -> {[], false}
      end

    heard =
      for {topic, ^fleet_id} <- state.topics, topic != Polls.fleet_topic(fleet_id), do: topic

    wanted = Enum.map(open, &Polls.topic(&1.id))
    added = wanted -- heard

    Enum.each(heard -- wanted, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
    Enum.each(added, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))

    topics =
      state.topics
      |> Map.drop(heard)
      |> Map.merge(Map.new(wanted, &{&1, fleet_id}))

    state = closing(%{state | topics: topics}, fleet_id, if(read?, do: open, else: []))
    if added == [], do: state, else: due(state, fleet_id)
  end

  defp closing(state, fleet_id, open) do
    {timer, closing} = Map.pop(state.closing, fleet_id)
    if timer, do: Process.cancel_timer(timer)

    case Enum.map(open, & &1.closes_at) do
      [] ->
        %{state | closing: closing}

      times ->
        wait = max(DateTime.diff(Enum.min(times, DateTime), DateTime.utc_now(), :millisecond), 0)
        timer = Process.send_after(self(), {:closes, fleet_id}, wait + @after_close)
        %{state | closing: Map.put(closing, fleet_id, timer)}
    end
  end

  @doc """
  Reads `fleet_id`'s polls and puts its readings, deleting the polls its
  list no longer holds. What the producer runs on each pass.

  Each poll's page is put before the list naming it, so a page that finds a
  poll on the list finds its page held too.
  """
  def read(fleet_id) do
    held = held(fleet_id)

    # A failed database read is a read not taken, never a reason for this
    # process, and the site with it, to stop. It is logged and saved with the
    # site's errors as a page's own read is (`KeyfleetWeb.PageRead`), so one
    # that keeps failing is seen at /admin/errors.
    case PageRead.run("polls", fn -> reading(fleet_id) end) do
      {:ok, {listing, polls}} ->
        Enum.each(polls, &SharedReading.put(poll_key(fleet_id, &1.id), &1))
        SharedReading.put(key(fleet_id), listing)
        kept = MapSet.new(polls, &"#{fleet_id}:#{&1.id}")

        for id <- held, id not in kept, do: SharedReading.delete({:poll, id})

      {:error, _not_read} ->
        degraded(fleet_id)
    end
  end

  defp degraded(fleet_id) do
    SharedReading.degraded(key(fleet_id))
    Enum.each(held(fleet_id), &SharedReading.degraded({:poll, &1}))
  end

  # The list carries no poll's choices; only a poll's own page shows them.
  defp reading(fleet_id) do
    case Fleets.get_fleet!(fleet_id) do
      nil ->
        {%{fleet_name: nil, deployed?: false, polls: []}, []}

      fleet ->
        # Taken before the read, so a poll counted open here has no result
        # yet, and one counted closed has its result.
        now = DateTime.utc_now()
        polls = fleet_id |> Polls.list_polls!(actor: nil) |> Enum.map(&PollsLive.public(&1, now))

        {%{
           fleet_name: fleet.name,
           deployed?: fleet.manager_address != nil,
           polls: Enum.map(polls, &Map.delete(&1, :choices))
         }, polls}
    end
  end

  # The trailing ":" keeps one fleet's ids from matching another's.
  defp held(fleet_id),
    do: Enum.filter(SharedReading.ids(:poll), &String.starts_with?(&1, fleet_id <> ":"))
end
