defmodule KeyFleet.Chain.Supervisor do
  @moduledoc "One `KeyFleet.Chain.Poller` for each deployed fleet."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    KeyFleet.Fleets.list_deployed_fleets!()
    |> Enum.map(&{KeyFleet.Chain.Poller, &1})
    |> Supervisor.init(strategy: :one_for_one)
  end
end
