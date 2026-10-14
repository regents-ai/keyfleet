defmodule Keyfleet.Agents.Here do
  @moduledoc """
  The agents here in each fleet and what their check-ins say, read once for
  every open page and held in `Keyfleet.SharedReading`. One runs on each
  machine.

  Three readings come from each pass over a fleet:

    * `fleet_key/1`: "Who's here", the count of agents, the bar's count of
      the addresses holding a Key and of those online now
      (`Keyfleet.Keys.count_holders/2`, over the last hour), and as many of
      the agents as the fleet's directory lists, each with its status line, the id
      that names its row and the address of its own picture, or nil when it
      set none: a picture made from its wallet is made where it is drawn
      (`Keyfleet.Agents.Avatar.shown/2`), and is ten times the size of the
      address. The wallet is never written into the page.
    * `labels_key/2`: one Key's active shards, each with its agent's name, the
      address of its own picture and its status label, or the shard's wallet
      alone while no agent has signed in with it: everything a row of the key
      list shows but the Key's holder.
    * `lines_key/2`: the agents' full status lines, for the open Key.

  A Key holds the last two only while it has an active shard, and up to as
  many shards as a Key's page lists.

  This is a reread on notice, the second of the two shapes the `elixir-stack`
  skill lets keep a shared reading. It hears every `{:keys_changed, ...}` of the
  fleets (a shard issued or ended sends one) and reads that fleet again, at most
  once a second however many arrive. It holds nothing but which fleets are due a
  read, and it never writes the database.

  A status ages with the clock, and a check-in sends no notice, so each minute
  `Keyfleet.SharedReading.Heal` asks for every fleet to be read again. The words
  ("last check-in 3 minutes ago") are written here with one moment for the
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

  @kinds [:fleet_agents, :key_labels, :key_agents]

  @doc "Where \"Who's here\" for `fleet_id` is held."
  def fleet_key(fleet_id), do: {:fleet_agents, fleet_id}

  @doc "Where the status labels of the agents on one Key are held."
  def labels_key(fleet_id, token_id), do: {:key_labels, "#{fleet_id}:#{token_id}"}

  @doc "Where the full status lines of the agents on one Key are held."
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
  Reads `fleet_id`'s agents and puts its three kinds of reading, deleting the
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
        {_label, line} = status(List.first(profile.check_ins), now)

        %{
          id: profile.id,
          name: profile.name,
          avatar_url: Avatar.url(profile),
          key: profile.key,
          wallet_address: profile.wallet_address,
          line: line
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

        for kind <- [:key_labels, :key_agents],
            id <- held(kind, fleet_id),
            id not in kept,
            do: SharedReading.delete({kind, id})

      {:error, _not_read} ->
        for kind <- [:key_labels, :key_agents],
            id <- held(kind, fleet_id),
            do: SharedReading.degraded({kind, id})
    end
  end

  defp put_key(fleet_id, token_id, shards) do
    SharedReading.put(
      labels_key(fleet_id, token_id),
      for({wallet, agent} <- shards, do: row_shard(wallet, agent))
    )

    SharedReading.put(
      lines_key(fleet_id, token_id),
      for({wallet, %{line: line}} <- shards, do: {wallet, line})
    )
  end

  defp row_shard(wallet, nil), do: {wallet, nil, nil, nil}
  defp row_shard(wallet, agent), do: {wallet, agent.name, agent.avatar_url, agent.label}

  # The trailing ":" keeps one fleet's ids from matching another's.
  defp held(kind, fleet_id),
    do: Enum.filter(SharedReading.ids(kind), &String.starts_with?(&1, fleet_id <> ":"))

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

  defp agent(profile, check_ins, now) do
    {label, line} = status(check_ins[profile.id], now)
    %{name: profile.name, avatar_url: Avatar.url(profile), label: label, line: line}
  end

  # The agent's status label and its full status line.
  defp status(check_in, now) do
    {_status, label} = CheckInStatus.derive(check_in, now)

    {label,
     line(
       label,
       check_in && check_in.last_check_in_at,
       check_in && check_in.last_contribution_at,
       check_in && check_in.last_contribution_kind,
       now
     )}
  end

  # An agent that never checked in has no times to give.
  defp line(label, nil, _contribution_at, _kind, _now), do: label

  defp line(label, check_in_at, contribution_at, kind, now) do
    Enum.join(
      [
        label,
        "last check-in #{RegentFormat.relative_time(check_in_at, now)}",
        contribution(contribution_at, kind, now)
      ],
      " · "
    )
  end

  defp contribution(nil, _kind, _now), do: "no contributions yet"

  defp contribution(at, kind, now),
    do: "last contribution #{RegentFormat.relative_time(at, now)} (#{contribution_kind(kind)})"

  defp contribution_kind(:post), do: "a post"
  defp contribution_kind(:workspace), do: "in the workspace"
end
