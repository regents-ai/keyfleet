defmodule Keyfleet.Chain.Repeat do
  @moduledoc """
  Runs one chain read for one deployed fleet again and again, apart from the
  `Keyfleet.Chain.Poller`, so a slow read never holds up the reading of the
  fleet's history: `module.read(fleet, client)` now and then every `every`
  milliseconds.

  A read that fails is tried again after twice the wait before it, up to
  five minutes (or `every`, if that is longer), and the wait returns to
  `every` once a read succeeds. A failure is logged as a warning when it
  first differs from the one before, so the same failure is logged once. A
  read that raises is logged as an error with its stacktrace, and is waited
  on as a failure, so one bad read cannot bring down the fleets' supervisor.
  """
  use GenServer

  require Logger

  alias Keyfleet.Chain.Client

  @longest_wait 5 * 60 * 1_000

  def child_spec({module, fleet, _every} = args),
    do: %{id: {module, fleet.id}, start: {__MODULE__, :start_link, [args]}}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({module, fleet, every}) do
    send(self(), :read)

    {:ok,
     %{
       module: module,
       fleet: fleet,
       every: every,
       wait: every,
       failure: nil,
       client: Client.configured()
     }}
  end

  @impl true
  def handle_info(:read, state) do
    state = after_read(read(state), state)
    Process.send_after(self(), :read, state.wait)
    {:noreply, state}
  end

  defp after_read({:error, reason}, state) do
    wait = longer(state)

    if reason != state.failure do
      Logger.warning(
        "Fleet #{state.fleet.id}: #{inspect(state.module)} failed (#{inspect(reason)}); " <>
          "trying again in #{wait} ms."
      )
    end

    %{state | wait: wait, failure: reason}
  end

  defp after_read(:raised, state), do: %{state | wait: longer(state)}
  defp after_read(_read, state), do: %{state | wait: state.every, failure: nil}

  defp longer(state), do: min(state.wait * 2, max(state.every, @longest_wait))

  defp read(%{module: module, fleet: fleet, client: client}) do
    module.read(fleet, client)
  rescue
    exception ->
      Logger.error(
        "Fleet #{fleet.id}: #{inspect(module)} raised; it is tried again later.\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :raised
  end
end
