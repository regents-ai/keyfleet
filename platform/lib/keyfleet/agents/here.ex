defmodule Keyfleet.Agents.Here do
  @moduledoc """
  The agents here in each fleet and what their check-ins say, read once for
  every open page and held in `Keyfleet.SharedReading`. One runs on each
  machine.

  Two readings come from each pass over a fleet:

    * `fleet_key/1`: "Who's here", the count of agents, the bar's count of
      the addresses holding a Key and of those online now
      (`Keyfleet.Keys.count_holders/2`, over the last hour), and as many of
      the agents as the fleet's directory lists, each with what its check-ins
      say (its light, the light's meaning and when it was last seen), the id
      that names its row and the address of its own picture, or nil when it
      set none: a picture made from its wallet is made where it is drawn
      (`Keyfleet.Agents.Avatar.shown/2`), and is ten times the size of the
      address. The wallet is never written into the page.
    * `lines_key/2`: what each agent's check-ins say, by wallet, for the open
      Key.

  A Key holds the second only while it has an active shard, and up to as
  many shards as a Key's page lists.

  This is a reread on notice, the second of the two shapes the `elixir-stack`
  skill lets keep a shared reading. It hears every `{:keys_changed, ...}` of the
  fleets (a shard issued or ended sends one) and reads that fleet again, at most
  once a second however many arrive. It holds nothing but which fleets are due a
  read, and it never writes the database.

  A status ages with the clock, and a check-in sends no notice, so each minute
  `Keyfleet.SharedReading.Heal` asks for every fleet to be read again. The words
  ("Seen 3 minutes ago") are written here with one moment for the
  whole pass, never on the page, so a page wakes only when what it shows has
  changed (`ash-frontend`, `references/public-figures.md`).

  The first read happens as it starts, so each fleet holds a reading or its
  degraded mark before the site serves a page.
  """

  use GenServer

  alias Keyfleet.{Agents, Directory, Fleets, Keys, SharedReading}
  alias Keyfleet.Agents.{Avatar, CheckInStatus}

  # As many of a Key's agents as its page lists (`Keyfleet.Keys.Profile`).
  @listed 100

  @kinds [:fleet_agents, :key_agents]

  @doc "Where \"Who's here\" for `fleet_id` is held."
  def fleet_key(fleet_id), do: {:fleet_agents, fleet_id}

  @doc "Where what the check-ins of the agents on one Key say is held."
  def lines_key(fleet_id, token_id), do: {:key_agents, "#{fleet_id}:#{token_id}"}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    Enum.each(@kinds, &SharedReading.subscribe_heal/1)

    for fleet_id <- Fleets.catalog_ids(),
        do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(fleet_id))

    Enum.each(Fleets.catalog_ids(), &read/1)
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_info({:keys_changed, fleet_id, _token_ids}, due), do: {:noreply, due(due, fleet_id)}

  def handle_info({:shared_reading_heal, _kind}, due),
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

  @doc """
  Reads `fleet_id`'s agents and puts its two kinds of reading, deleting the
  Keys no agent works on any more. What the producer runs on each pass.
  """
  def read(fleet_id) do
    now = DateTime.utc_now()
    read_here(fleet_id, now)
    read_keys(fleet_id, now)
  end

  defp read_here(fleet_id, now) do
    case here(fleet_id, now) do
      {:ok, reading} -> SharedReading.put(fleet_key(fleet_id), reading)
      {:error, _not_read} -> SharedReading.degraded(fleet_key(fleet_id))
    end
  end

  defp here(fleet_id, now) do
    agents =
      for profile <- Agents.agents_here!(fleet_id, query: [limit: Directory.agents_shown()]) do
        %{
          id: profile.id,
          name: profile.name,
          avatar_url: Avatar.url(profile),
          key: profile.key,
          wallet_address: profile.wallet_address,
          seen: seen(List.first(profile.check_ins), now)
        }
      end

    count =
      case Agents.count_agents_here(fleet_id) do
        {:ok, count} -> count
        {:error, _failure} -> nil
      end

    holders =
      case Keys.count_holders(fleet_id, DateTime.add(now, -1, :hour)) do
        {:ok, holders} -> holders
        {:error, _failure} -> nil
      end

    {:ok, %{here: count, agents: agents, holders: holders}}
  rescue
    # The database not answering raises beneath Ash. It is a read not taken,
    # never a reason for this process, and the site with it, to stop.
    error in [Ash.Error.Unknown, DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp read_keys(fleet_id, now) do
    case on_keys(fleet_id, now) do
      {:ok, by_key} ->
        Enum.each(by_key, fn {token_id, shards} -> put_key(fleet_id, token_id, shards) end)
        kept = MapSet.new(by_key, fn {token_id, _shards} -> "#{fleet_id}:#{token_id}" end)

        for id <- held(fleet_id),
            id not in kept,
            do: SharedReading.delete({:key_agents, id})

      {:error, _not_read} ->
        for id <- held(fleet_id),
            do: SharedReading.degraded({:key_agents, id})
    end
  end

  defp put_key(fleet_id, token_id, shards) do
    SharedReading.put(
      lines_key(fleet_id, token_id),
      for({wallet, %{} = seen} <- shards, do: {wallet, seen})
    )
  end

  # The trailing ":" keeps one fleet's ids from matching another's.
  defp held(fleet_id),
    do: Enum.filter(SharedReading.ids(:key_agents), &String.starts_with?(&1, fleet_id <> ":"))

  # Every active shard in the fleet by Key, each with the agent that signed in
  # with it, if one has, and what its check-ins with the fleet say.
  defp on_keys(fleet_id, now) do
    shards = Keys.active_shards_in_fleet!(fleet_id, load: [:agent_profile])

    check_ins =
      for(%{agent_profile: %{id: id}} <- shards, uniq: true, do: id)
      |> Enum.chunk_every(100)
      |> Enum.flat_map(&Agents.check_ins_in_fleet!(fleet_id, &1))
      |> Map.new(&{&1.agent_profile_id, &1})

    {:ok,
     shards
     |> Enum.group_by(& &1.token_id, &{&1.wallet, agent(&1.agent_profile, check_ins, now)})
     |> Map.new(fn {token_id, shards} -> {token_id, Enum.take(shards, @listed)} end)}
  rescue
    error in [Ash.Error.Unknown, DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp agent(nil, _check_ins, _now), do: nil

  defp agent(profile, check_ins, now), do: seen(check_ins[profile.id], now)

  # What the agent's check-ins say: its light, what the light means, and one
  # short line of when it was last seen and last did something.
  defp seen(check_in, now) do
    {_status, label} = CheckInStatus.derive(check_in, now)
    %{light: CheckInStatus.light(check_in, now), label: label, line: line(check_in, now)}
  end

  defp line(nil, _now), do: "Not seen yet"

  # Seen is whichever came last, a check-in or a contribution: an agent that
  # posted after its last check-in was seen then.
  defp line(check_in, now) do
    seen_at =
      [check_in.last_check_in_at, check_in.last_contribution_at]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime)

    Enum.join(
      [
        "Seen #{RegentFormat.relative_time(seen_at, now)}"
        | contribution(check_in.last_contribution_at, check_in.last_contribution_kind, now)
      ],
      " · "
    )
  end

  defp contribution(nil, _kind, _now), do: []

  defp contribution(at, kind, now),
    do: ["#{contributed(kind)} #{RegentFormat.relative_time(at, now)}"]

  defp contributed(:post), do: "posted"
  defp contributed(:workspace), do: "worked"
end
