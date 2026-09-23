defmodule KeyFleet.Rooms.Validations.FleetLevel do
  @moduledoc """
  The level a topic room follows, if any, is one of its fleet's levels. Only
  the two Fibonacci fleets have levels.
  """
  use Ash.Resource.Validation

  alias KeyFleet.Fleets.Presets

  @impl true
  def validate(changeset, _opts, _context) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    level = Ash.Changeset.get_attribute(changeset, :level)

    if is_nil(level) or Presets.levelled?(fleet_id),
      do: :ok,
      else: {:error, field: :level, message: "is not one of this fleet's levels"}
  end
end
