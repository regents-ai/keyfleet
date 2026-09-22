defmodule KeyFleet.Rooms do
  @moduledoc "Fleet-scoped rooms for native chat."
  use Ash.Domain

  @core_rooms [{"general", "General"}, {"planning", "Planning"}, {"work", "Work"}]

  resources do
    resource KeyFleet.Rooms.Room do
      define :list_rooms, action: :for_fleet, args: [:fleet_id]
    end
  end

  @doc """
  Ensures the three core rooms for every persisted fleet from trusted setup code.

  Reruns preserve room identities and restore canonical names. The whole bootstrap
  commits together. This internal entry point must never be exposed as a user action.
  """
  def bootstrap_core_rooms! do
    KeyFleet.Repo.transaction(fn ->
      fleets = KeyFleet.Fleets.list_fleets!() |> Enum.sort_by(& &1.id)

      if length(fleets) != 4 do
        raise "Core room bootstrap requires the complete fixed fleet catalog"
      end

      for fleet <- fleets, {slug, name} <- @core_rooms do
        KeyFleet.Rooms.Room
        |> Ash.Changeset.for_create(:bootstrap, %{fleet_id: fleet.id, slug: slug, name: name},
          actor: %KeyFleet.Actors.System{}
        )
        |> Ash.create!()
      end
    end)
    |> case do
      {:ok, rooms} -> rooms
      {:error, reason} -> raise "Core room bootstrap failed: #{inspect(reason)}"
    end
  end
end
