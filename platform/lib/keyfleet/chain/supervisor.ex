defmodule Keyfleet.Chain.Supervisor do
  @moduledoc """
  For each deployed fleet, one `Keyfleet.Chain.Poller` reading its history,
  and apart from it, its balances and rewards, read every minute.
  """
  use Supervisor

  alias Keyfleet.Chain.Repeat

  @balances_every 60_000

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Keyfleet.Fleets.list_deployed_fleets!()
    |> Enum.flat_map(
      &[
        {Keyfleet.Chain.Poller, &1},
        {Repeat, {Keyfleet.Chain.TreasuryReader, &1, @balances_every}}
      ]
    )
    |> Supervisor.init(strategy: :one_for_one)
  end
end
