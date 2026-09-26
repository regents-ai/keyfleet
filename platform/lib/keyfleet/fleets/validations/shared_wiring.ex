defmodule Keyfleet.Fleets.Validations.SharedWiring do
  @moduledoc """
  Every deployed fleet sells on one chain, for one USDC, admits deposits
  through one asset registry and draws traits from one trait table, so a
  deployment whose wiring differs from any other bound fleet's is refused.

  It runs inside the action's transaction and first locks every fleet row, in
  id order, so two recordings for different fleets are checked one after the
  other: the second waits for the first to commit and then sees its wiring.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @fields [:chain_id, :usdc_address, :asset_registry_address, :trait_table_hash]

  @impl true
  def validate(changeset, _opts, _context) do
    fleets =
      changeset.resource
      |> Ash.Query.sort(:id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read!()

    mismatch =
      for bound <- fleets,
          bound.id != changeset.data.id and bound.contract_address != nil,
          field <- @fields,
          Map.fetch!(bound, field) != Ash.Changeset.get_attribute(changeset, field) do
        {field, bound.id}
      end

    case mismatch do
      [] -> :ok
      [{field, id} | _] -> {:error, field: field, message: "differs from #{id}'s"}
    end
  end
end
