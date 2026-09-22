defmodule KeyFleet.Fleets do
  @moduledoc "The fixed fleet catalog."
  use Ash.Domain

  @catalog [
    %{id: "fibonacci_syndicate", name: "Fibonacci Syndicate"},
    %{id: "fibonacci_cascade", name: "Fibonacci Cascade"},
    %{id: "fleet_tech_classic", name: "Fleet.Tech Classic"},
    %{id: "fleet_tech_accelerant", name: "Fleet.Tech Accelerant"}
  ]

  resources do
    resource KeyFleet.Fleets.Fleet do
      define :list_fleets, action: :read
    end
  end

  @doc """
  Seeds the fixed catalog from trusted application setup code.

  Reruns preserve machine identities and restore canonical display names. The
  whole catalog commits together. This internal entry point must never be exposed
  as a user action.
  """
  def bootstrap_catalog! do
    %Ash.BulkResult{records: fleets} =
      Ash.bulk_create!(@catalog, KeyFleet.Fleets.Fleet, :bootstrap,
        actor: %KeyFleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    fleets
  end
end
