defmodule KeyFleet.Chain.Poller do
  @moduledoc """
  Keeps one deployed fleet's key ownership current by running
  `KeyFleet.Chain.Scanner` every few seconds.

  It first proves the node serves the fleet's chain and refuses to read at all
  otherwise. A failed read is logged and retried after a delay that doubles up
  to a minute; nothing that goes wrong in a pass stops the poller.
  """
  use GenServer

  require Logger

  alias KeyFleet.Chain.Client
  alias KeyFleet.Chain.Scanner

  @max_delay 60_000

  def child_spec(fleet),
    do: %{id: {__MODULE__, fleet.id}, start: {__MODULE__, :start_link, [fleet]}}

  def start_link(fleet), do: GenServer.start_link(__MODULE__, fleet)

  @impl true
  def init(fleet) do
    interval = Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:poll_interval_ms]
    send(self(), :tick)

    {:ok,
     %{
       fleet: fleet,
       client: Client.configured(),
       interval: interval,
       delay: interval,
       chain?: false
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    case tick(state) do
      {:ok, state} ->
        Process.send_after(self(), :tick, state.interval)
        {:noreply, %{state | delay: state.interval}}

      :refused ->
        {:noreply, state}

      {:error, reason, state} ->
        delay = min(state.delay * 2, @max_delay)

        Logger.warning(
          "Reading fleet #{state.fleet.id} failed, retrying in #{delay} ms: #{inspect(reason)}"
        )

        Process.send_after(self(), :tick, delay)
        {:noreply, %{state | delay: delay}}
    end
  end

  defp tick(%{chain?: false, fleet: fleet, client: client} = state) do
    case client.chain_id() do
      {:ok, chain_id} when chain_id == fleet.chain_id ->
        tick(%{state | chain?: true})

      {:ok, chain_id} ->
        Logger.error(
          "Fleet #{fleet.id} is deployed on chain #{fleet.chain_id} but the node serves chain #{chain_id}; not reading it."
        )

        :refused

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp tick(%{fleet: fleet, client: client} = state) do
    case Scanner.step(fleet, client) do
      :ok -> {:ok, state}
      {:stopped, _block} -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    # A database or node failure mid-pass leaves the cursor where it was, so the
    # pass is simply retried.
    exception -> {:error, exception, state}
  end
end
