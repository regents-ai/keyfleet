defmodule Keyfleet.Chain.Watch do
  @moduledoc """
  Every minute (`config :keyfleet, Oban, cron:`), where a node is configured
  (`KEYFLEET_RPC_URL`): makes sure each deployed fleet has a
  `Keyfleet.Chain.ReadFleet` job reading its history, and queues a
  `Keyfleet.Chain.ReadBalances` reading of its balances. A fleet recorded
  while the site runs is read from the next minute on.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Keyfleet.Chain.ReadBalances
  alias Keyfleet.Chain.ReadFleet

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:rpc_url] do
      Keyfleet.Fleets.list_deployed_fleets!()
      |> Enum.flat_map(&[ReadFleet.new(%{fleet_id: &1.id}), ReadBalances.new(%{fleet_id: &1.id})])
      |> Enum.each(&Oban.insert!/1)
    end

    :ok
  end
end
