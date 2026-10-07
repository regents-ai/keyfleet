defmodule Keyfleet.Chain.ReadBalances do
  @moduledoc """
  One `Keyfleet.Chain.TreasuryReader` reading of a deployed fleet's
  balances, queued every minute by `Keyfleet.Chain.Watch`, apart from the
  reading of its history, so a slow read never holds that up. A reading that
  fails is logged and tried again a few times; the next minute's reading
  follows either way.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 3,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  require Logger

  alias Keyfleet.Chain.Client
  alias Keyfleet.Chain.TreasuryReader
  alias Keyfleet.Fleets

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    with %{contract_address: address} = fleet when is_binary(address) <-
           Fleets.get_fleet!(fleet_id),
         {:error, reason} <- TreasuryReader.read(fleet, Client.configured()) do
      Logger.warning("Fleet #{fleet_id}: reading its balances failed: #{inspect(reason)}")
      {:error, reason}
    else
      {:ok, _reading} -> :ok
      _not_deployed -> {:cancel, :not_deployed}
    end
  end
end
