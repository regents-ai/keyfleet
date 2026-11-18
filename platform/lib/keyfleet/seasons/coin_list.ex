defmodule Keyfleet.Seasons.CoinList do
  @moduledoc """
  The products a pick may name now (`Keyfleet.Seasons.Coinbase.eligible/0`),
  read once for every pick and held in `Keyfleet.SharedReading` under `key/0`.
  One runs on each machine that serves pages.

  This is a reread on notice, one of the two shapes the `elixir-stack` skill
  lets keep a shared reading: every ten minutes `Keyfleet.SharedReading.Heal`
  asks for the list to be read again, so Coinbase is asked at most once in ten
  minutes on each machine, however many picks arrive. It holds nothing, and it
  never writes the database.

  The first read follows its start, so the site's start never waits on
  Coinbase. Until it has a reading, or while its last read failed, a pick is
  refused as not checked; the season's start checks every pick again anyway.
  """

  use GenServer

  alias Keyfleet.Seasons.Coinbase
  alias Keyfleet.SharedReading

  @kind :season_coins

  @doc "Where the list is held."
  def key, do: {@kind, "coinbase"}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(@kind)
    {:ok, nil, {:continue, :read}}
  end

  @impl true
  def handle_continue(:read, state) do
    read()
    {:noreply, state}
  end

  @impl true
  def handle_info({:shared_reading_heal, @kind}, state) do
    read()
    {:noreply, state}
  end

  @doc "Reads the list now and holds it, or marks it not read."
  def read do
    with {:ok, product_ids} <- Coinbase.eligible(),
         :ok <- SharedReading.put(key(), product_ids) do
      :ok
    else
      {:error, _not_held} -> SharedReading.degraded(key())
    end
  end

  @doc "Whether `product` may be picked, by the list read last."
  @spec check(String.t()) :: :ok | {:error, :ineligible | :unavailable}
  def check(product) do
    case SharedReading.fetch(key()) do
      {:ok, %{reading: [_ | _] = product_ids, degraded?: false}} ->
        if product in product_ids, do: :ok, else: {:error, :ineligible}

      _not_read ->
        {:error, :unavailable}
    end
  end
end
