defmodule Keyfleet.Chain.Supervisor do
  @moduledoc """
  For each deployed fleet, one `Keyfleet.Chain.Poller` reading its history,
  and apart from it, the launches its launch proposals approve, read every
  few seconds, and its balances, read once a minute.
  """
  use Supervisor

  alias Keyfleet.Chain.Repeat

  @balances_every 60_000

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    poll_interval = Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:poll_interval_ms]

    Keyfleet.Fleets.list_deployed_fleets!()
    |> Enum.flat_map(
      &[
        {Keyfleet.Chain.Poller, &1},
        {Repeat, {Keyfleet.Chain.LaunchEnvelopes, &1, poll_interval}},
        {Repeat, {Keyfleet.Chain.TreasuryReader, &1, @balances_every}}
      ]
    )
    |> Supervisor.init(strategy: :one_for_one)
  end
end
