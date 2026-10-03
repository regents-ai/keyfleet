defmodule Keyfleet.Notebooks.AccessCache do
  @moduledoc """
  Who was let into a fleet's notebooks in the last `access_ttl_ms`, so the
  gateway checks key ownership at most that often for each of them. Only a
  yes is kept. `Keyfleet.Notebooks.end_access/2` clears an entry on every
  node at once; this process owns the table and hears it.
  """
  use GenServer

  @table __MODULE__
  @topic "notebook_access"

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Where every node hears that someone's access ended."
  def topic, do: @topic

  @doc "Whether `subject` was let into the fleet's notebooks recently enough to go in again unchecked."
  def admitted?(fleet_id, subject) do
    case :ets.lookup(@table, {fleet_id, subject}) do
      [{_key, until}] -> until > now()
      [] -> false
    end
  end

  @doc "Records that `subject` was just let into the fleet's notebooks."
  def admit(fleet_id, subject) do
    ttl = Keyfleet.Notebooks.config()[:access_ttl_ms]
    :ets.insert(@table, {{fleet_id, subject}, now() + ttl})
    :ok
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, @topic)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:notebook_access_ended, fleet_id, subject}, state) do
    :ets.delete(@table, {fleet_id, subject})
    {:noreply, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
