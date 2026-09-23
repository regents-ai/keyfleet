defmodule KeyFleet.Chain.Repeat do
  @moduledoc """
  Runs one chain read for one deployed fleet again and again, apart from the
  `KeyFleet.Chain.Poller`, so a slow read never holds up the reading of the
  fleet's history: `module.read(fleet, client)` now and then every `every`
  milliseconds. A read that fails or raises is logged, and the next one goes
  ahead as planned.
  """
  use GenServer

  require Logger

  alias KeyFleet.Chain.Client

  def child_spec({module, fleet, _every} = args),
    do: %{id: {module, fleet.id}, start: {__MODULE__, :start_link, [args]}}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({module, fleet, every}) do
    send(self(), :read)
    {:ok, %{module: module, fleet: fleet, every: every, client: Client.configured()}}
  end

  @impl true
  def handle_info(:read, %{module: module, fleet: fleet, every: every} = state) do
    case read(state) do
      {:error, reason} ->
        Logger.warning(
          "Fleet #{fleet.id}: #{inspect(module)} failed (#{inspect(reason)}); " <>
            "trying again in #{every} ms."
        )

      _read ->
        :ok
    end

    Process.send_after(self(), :read, every)
    {:noreply, state}
  end

  defp read(%{module: module, fleet: fleet, client: client}) do
    module.read(fleet, client)
  rescue
    # A database or node failure is tried again at the next read.
    exception -> {:error, exception}
  end
end
