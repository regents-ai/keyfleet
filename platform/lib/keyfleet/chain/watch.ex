defmodule Keyfleet.Chain.Watch do
  @moduledoc """
  Every five minutes (`config :keyfleet, Oban, cron:`), where a node is
  configured (`KEYFLEET_RPC_URL`): makes sure each deployed fleet has a
  `Keyfleet.Chain.ReadFleet` job reading its history, and queues a
  `Keyfleet.Chain.ReadBalances` reading of its balances. A fleet recorded
  while the site runs is read from the next turn on, or sooner when a
  person's on-chain press lands (`refresh/1`).

  With fleets deployed and no node named, nothing reads them; each turn says
  so with the site's errors (`Keyfleet.Chain.ReadingStoppedError`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @behaviour Keyfleet.ChainRefresh

  alias Keyfleet.Chain.ReadBalances
  alias Keyfleet.Chain.ReadFleet
  alias Keyfleet.Chain.ReadingStoppedError
  alias Keyfleet.ChainRefresh

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    fleets = Keyfleet.Fleets.list_deployed_fleets!()
    read(fleets, Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:rpc_url])
    :ok
  end

  @doc """
  A person's on-chain press on chain `chain_id` landed: each fleet deployed on
  it reads its history ten seconds from now, instead of at its next turn, and
  its balances at once. A history read already under way is left to finish.
  """
  @impl ChainRefresh
  def refresh(chain_id) do
    Keyfleet.Fleets.list_deployed_fleets!()
    |> Enum.filter(&(&1.chain_id == chain_id))
    |> Enum.flat_map(&[soon(&1), ReadBalances.new(%{fleet_id: &1.id})])
    |> Enum.each(&Oban.insert!/1)
  end

  defp soon(fleet) do
    ReadFleet.new(%{fleet_id: fleet.id},
      schedule_in: ChainRefresh.gap_s(),
      replace: [scheduled: [:scheduled_at], retryable: [:scheduled_at]]
    )
  end

  defp read([], _rpc_url), do: :ok

  defp read(fleets, nil) do
    ReadingStoppedError.report(
      "No fleet is being read: KEYFLEET_RPC_URL names no node. Deployed fleets waiting: " <>
        "#{length(fleets)}. Set it to a Base node; the watch starts reading within five minutes."
    )

    :ok
  end

  defp read(fleets, _rpc_url) do
    fleets
    |> Enum.flat_map(&[ReadFleet.new(%{fleet_id: &1.id}), ReadBalances.new(%{fleet_id: &1.id})])
    |> Enum.each(&Oban.insert!/1)
  end
end
