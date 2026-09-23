defmodule KeyFleet.Keeper.Supervisor do
  @moduledoc """
  Keeps the keeper's `KeyFleet.Keeper.Runner` running, apart from the site.

  A Runner that crashes is started again, up to three restarts within a
  minute; past that this supervisor gives up and ends, and OTP logs that it
  reached its restart limit. The site starts it as `:temporary`, so it keeps
  serving without the keeper until it is restarted.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([KeyFleet.Keeper.Runner],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
