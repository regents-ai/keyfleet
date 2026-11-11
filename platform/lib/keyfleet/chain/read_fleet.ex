defmodule Keyfleet.Chain.ReadFleet do
  @moduledoc """
  Keeps one deployed fleet's history current. Each run is one
  `Keyfleet.Chain.Scanner` pass; the job then waits `:pass_interval_seconds`
  (five minutes) and runs again, for as long as the fleet is deployed. A pass
  reads one stretch of blocks at most, so one that ends with the record still
  behind the head it read runs again a second later, until it has caught up.
  A person's on-chain press that lands brings the next run forward to ten
  seconds later (`Keyfleet.Chain.Watch.refresh/1`). One job per fleet runs at
  a time, on whichever machine took it, and `Keyfleet.Chain.Watch` makes sure
  every deployed fleet has one.

  Each run first proves the node serves the fleet's chain, and otherwise
  reads nothing and stops, with an error logged and saved with the site's
  errors (`Keyfleet.Chain.ReadingStoppedError`); the watch tries again at its
  next turn. A node that does not answer is one warning line and a minute's
  wait, never a failure. Any other pass that fails is logged and retried a
  minute later, so one failure does not leave key ownership too old to act on
  (`Keyfleet.Chain.Cursor`'s seven minutes). A job that has failed 20 times
  is given up, and the watch starts a fresh one. A finished pass reports
  `[:keyfleet, :indexer, :lag]` with `blocks`, the head less the last block read.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  require Logger

  alias Keyfleet.Chain
  alias Keyfleet.Chain.Client
  alias Keyfleet.Chain.ReadingStoppedError
  alias Keyfleet.Chain.Scanner
  alias Keyfleet.Fleets

  @retry_after 60
  @catch_up_after 1

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
  def backoff(%Oban.Job{}), do: @retry_after

  defp pass(fleet, client) do
    with {:ok, chain_id} <- client.chain_id(),
         :ok <- same_chain(fleet, chain_id),
         {:error, reason} <- Scanner.step(fleet, client) do
      failed(fleet, reason)
    else
      :ok -> passed(fleet)
      {:error, reason} -> failed(fleet, reason)
      {:cancel, reason} -> {:cancel, reason}
      _read -> {:snooze, pass_interval()}
    end
  end

  # A finished pass reports how far the record trails the head it read
  # (`KeyfleetWeb.Telemetry`), always under the one indexer name "fleet".
  defp passed(fleet) do
    %{head_block: head, next_block: next} = Chain.get_cursor!(fleet.id)
    lag = max(head - (next - 1), 0)

    :telemetry.execute([:keyfleet, :indexer, :lag], %{blocks: lag}, %{
      indexer: "fleet",
      chain_id: fleet.chain_id
    })

    if lag > 0, do: {:snooze, @catch_up_after}, else: {:snooze, pass_interval()}
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
    if unanswered?(reason) do
      Logger.warning(
        "Fleet #{fleet.id} not read: the node did not answer; reading again in a minute: #{inspect(reason)}"
      )

      {:snooze, @retry_after}
    else
      Logger.warning("Reading fleet #{fleet.id} failed; it is tried again: #{inspect(reason)}")
      {:error, reason}
    end
  end

  # The node not answering. A single block it will not answer after the
  # stretch was halved down to it stays a failure, named in the error.
  defp unanswered?(reason) when reason in [:chain_unavailable, :chain_busy], do: true
  defp unanswered?({:block_unanswered, _block, :chain_busy}), do: true
  defp unanswered?({:regent_buyer_unread, reason}), do: unanswered?(reason)
  defp unanswered?(_reason), do: false

  defp pass_interval,
    do: Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:pass_interval_seconds]
end
