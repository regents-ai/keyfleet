defmodule Keyfleet.AccessCache do
  @moduledoc """
  Who was let into one of a fleet's private places lately (`:notebooks`,
  `:code`), so its gateway checks key ownership at most once in that place's
  time for each of them. Only a yes is kept, with what the check found.

  `end_access/3` clears one subject on every node at once and `end_fleet/2`
  everyone in one place of a fleet; this process owns the table and hears
  both.
  """
  use GenServer

  @table __MODULE__
  @topic "fleet_access"

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "What was found when `subject` was last let into `place` of the fleet, while it still holds: `{:ok, found}` or `:none`."
  def lookup(place, fleet_id, subject) do
    case :ets.lookup(@table, {place, fleet_id, subject}) do
      [{_key, until, found}] -> if until > now(), do: {:ok, found}, else: :none
      [] -> :none
    end
  end

  @doc "Records that `subject` was just let into `place` of the fleet, for `ttl_ms`."
  def admit(place, fleet_id, subject, found, ttl_ms) do
    :ets.insert(@table, {{place, fleet_id, subject}, now() + ttl_ms, found})
    :ok
  end

  @doc "The invalidation generation before an admission's canonical read."
  def generation, do: GenServer.call(__MODULE__, :generation)

  @doc "Records an admission only if no invalidation completed during its read."
  def admit_if_current(place, fleet_id, subject, found, ttl_ms, generation),
    do: GenServer.call(__MODULE__, {:admit, place, fleet_id, subject, found, ttl_ms, generation})

  @doc "Ends `subject`'s admission to `place` of the fleet on every node now."
  def end_access(place, fleet_id, subject),
    do: Phoenix.PubSub.broadcast(Keyfleet.PubSub, @topic, {:end_access, place, fleet_id, subject})

  @doc "Ends everyone's admission to `place` of the fleet on every node now."
  def end_fleet(place, fleet_id),
    do: Phoenix.PubSub.broadcast(Keyfleet.PubSub, @topic, {:end_fleet, place, fleet_id})

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, @topic)
    {:ok, new_generation()}
  end

  @impl GenServer
  def handle_call(:generation, _from, generation), do: {:reply, generation, generation}

  def handle_call({:admit, place, fleet_id, subject, found, ttl_ms, expected}, _from, generation) do
    if expected == generation do
      :ok = admit(place, fleet_id, subject, found, ttl_ms)
      {:reply, :ok, generation}
    else
      {:reply, :stale, generation}
    end
  end

  @impl GenServer
  def handle_info({:end_access, place, fleet_id, subject}, _generation) do
    :ets.delete(@table, {place, fleet_id, subject})
    {:noreply, new_generation()}
  end

  def handle_info({:end_fleet, place, fleet_id}, _generation) do
    :ets.match_delete(@table, {{place, fleet_id, :_}, :_, :_})
    {:noreply, new_generation()}
  end

  defp new_generation, do: System.unique_integer([:positive, :monotonic])

  defp now, do: System.monotonic_time(:millisecond)
end
