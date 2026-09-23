defmodule KeyFleet.Chain.Supervisor do
  @moduledoc """
  For each deployed fleet, one `KeyFleet.Chain.Poller` reading its history,
  and apart from it, the launches its launch proposals approve, read every
  few seconds, and its balances, read once a minute.
  """
  use Supervisor

  alias KeyFleet.Chain.Repeat

  @balances_every 60_000

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    poll_interval = Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:poll_interval_ms]

    KeyFleet.Fleets.list_deployed_fleets!()
    |> Enum.flat_map(
      &[
        {KeyFleet.Chain.Poller, &1},
        {Repeat, {KeyFleet.Chain.LaunchEnvelopes, &1, poll_interval}},
        {Repeat, {KeyFleet.Chain.TreasuryReader, &1, @balances_every}}
      ]
    )
    |> Supervisor.init(strategy: :one_for_one)
  end
end
