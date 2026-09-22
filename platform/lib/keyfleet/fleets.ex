defmodule KeyFleet.Fleets do
  @moduledoc "The fixed fleet catalog."
  use Ash.Domain

  @catalog [
    {"fibonacci_syndicate", "Fibonacci Syndicate"},
    {"fibonacci_cascade", "Fibonacci Cascade"},
    {"fleet_tech_classic", "Fleet.Tech Classic"},
    {"fleet_tech_accelerant", "Fleet.Tech Accelerant"}
  ]

  resources do
    resource KeyFleet.Fleets.Fleet do
      define :list_fleets, action: :read
    end
  end

  @doc """
  Seeds the fixed catalog from trusted application setup code.

  Reruns preserve machine identities and restore canonical display names.
  This internal entry point must never be exposed as a user action.
  """
  def bootstrap_catalog! do
    KeyFleet.Repo.transaction(fn ->
      Enum.map(@catalog, fn {id, name} ->
        KeyFleet.Fleets.Fleet
        |> Ash.Changeset.for_create(:bootstrap, %{id: id, name: name},
          actor: %KeyFleet.Actors.System{}
        )
        |> Ash.create!()
      end)
    end)
    |> case do
      {:ok, fleets} -> fleets
      {:error, reason} -> raise "Fleet catalog bootstrap failed: #{inspect(reason)}"
    end
  end
end
