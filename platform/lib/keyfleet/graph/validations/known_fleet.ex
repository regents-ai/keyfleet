defmodule KeyFleet.Graph.Validations.KnownFleet do
  @moduledoc "The request names one of the catalog's fleets, each of which has a workspace."
  use Ash.Resource.Validation

  alias KeyFleet.Graph.Errors.UnknownFleetError

  @impl true
  def supports(_opts), do: [Ash.ActionInput, Ash.Changeset, Ash.Query]

  @impl true
  def validate(%input_type{} = input, _opts, _context) do
    fleet_id = input_type.get_argument(input, :fleet_id)

    if fleet_id in KeyFleet.Fleets.catalog_ids(),
      do: :ok,
      else: {:error, UnknownFleetError.exception(fleet_id: fleet_id)}
  end
end
