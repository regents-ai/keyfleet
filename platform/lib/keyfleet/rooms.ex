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
    fleets = KeyFleet.Fleets.list_fleets!() |> Enum.sort_by(& &1.id)

    if not match?([_, _, _, _], fleets) do
      raise "Core room bootstrap requires the complete fixed fleet catalog"
    end

    inputs =
      for fleet <- fleets, {slug, name} <- @core_rooms do
        %{fleet_id: fleet.id, slug: slug, name: name}
      end

    %Ash.BulkResult{records: rooms} =
      Ash.bulk_create!(inputs, KeyFleet.Rooms.Room, :bootstrap,
        actor: %KeyFleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    rooms
  end
end
