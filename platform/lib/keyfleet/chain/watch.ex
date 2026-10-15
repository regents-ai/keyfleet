defmodule Keyfleet.Chain.Watch do
  @moduledoc """
  Every minute (`config :keyfleet, Oban, cron:`), where a node is configured
  (`KEYFLEET_RPC_URL`): makes sure each deployed fleet has a
  `Keyfleet.Chain.ReadFleet` job reading its history, and queues a
  `Keyfleet.Chain.ReadBalances` reading of its balances. A fleet recorded
  while the site runs is read from the next minute on.

  With fleets deployed and no node named, nothing reads them; each minute
  says so with the site's errors (`Keyfleet.Chain.ReadingStopped`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Keyfleet.Chain.ReadBalances
  alias Keyfleet.Chain.ReadFleet
  alias Keyfleet.Chain.ReadingStopped

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    fleets = Keyfleet.Fleets.list_deployed_fleets!()
    read(fleets, Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:rpc_url])
    :ok
  end

  defp read([], _rpc_url), do: :ok

  defp read(fleets, nil) do
    ReadingStopped.report(
      "No fleet is being read: KEYFLEET_RPC_URL names no node. Deployed fleets waiting: " <>
        "#{length(fleets)}. Set it to a Base node; the watch starts reading within a minute."
    )

    :ok
  end

  defp read(fleets, _rpc_url) do
    fleets
    |> Enum.flat_map(&[ReadFleet.new(%{fleet_id: &1.id}), ReadBalances.new(%{fleet_id: &1.id})])
    |> Enum.each(&Oban.insert!/1)
  end
end
