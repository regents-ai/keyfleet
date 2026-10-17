defmodule Keyfleet.Chain.ReadFleet do
  @moduledoc """
  Keeps one deployed fleet's history current. Each run is one
  `Keyfleet.Chain.Scanner` pass; the job then waits `:pass_interval_seconds`
  and runs again, for as long as the fleet is deployed. One job per fleet
  runs at a time, on whichever machine took it, and `Keyfleet.Chain.Watch`
  makes sure every deployed fleet has one.

  Each run first proves the node serves the fleet's chain, and otherwise
  reads nothing and stops, with an error logged and saved with the site's
  errors (`Keyfleet.Chain.ReadingStoppedError`); the watch tries again a minute
  later. A pass that fails is logged and retried after a wait that
  doubles up to a minute. A job that has failed 20 times is given up, and
  the watch starts a fresh one within a minute.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  require Logger

  alias Keyfleet.Chain.Client
  alias Keyfleet.Chain.ReadingStoppedError
  alias Keyfleet.Chain.Scanner
  alias Keyfleet.Fleets

  @longest_wait 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    case Fleets.get_fleet!(fleet_id) do
      %{manager_address: address} = fleet when is_binary(address) ->
        pass(fleet, Client.configured())

      _not_deployed ->
        {:cancel, :not_deployed}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(Integer.pow(2, attempt) * pass_interval(), @longest_wait)

  defp pass(fleet, client) do
    with {:ok, chain_id} <- client.chain_id(),
         :ok <- same_chain(fleet, chain_id),
         {:error, reason} <- Scanner.step(fleet, client) do
      failed(fleet, reason)
    else
      {:error, reason} -> failed(fleet, reason)
      {:cancel, reason} -> {:cancel, reason}
      _read -> {:snooze, pass_interval()}
    end
  end

  defp same_chain(%{chain_id: chain_id}, chain_id), do: :ok

  defp same_chain(fleet, chain_id) do
    message =
      "Fleet #{fleet.id} is deployed on chain #{fleet.chain_id} but the node serves chain #{chain_id}; not reading it."

    Logger.error(message)
    ReadingStoppedError.report(message)
    {:cancel, {:wrong_chain, chain_id}}
  end

  defp failed(fleet, reason) do
    Logger.warning("Reading fleet #{fleet.id} failed; it is tried again: #{inspect(reason)}")
    {:error, reason}
  end

  defp pass_interval,
    do: Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:pass_interval_seconds]
end
