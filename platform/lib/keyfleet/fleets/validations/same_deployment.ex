defmodule KeyFleet.Fleets.Validations.SameDeployment do
  @moduledoc """
  A fleet is bound to one deployment for good: an unbound fleet takes any
  deployment, a bound one only the deployment it already has.
  """
  use Ash.Resource.Validation

  @fields [
    :chain_id,
    :contract_address,
    :rewards_address,
    :votes_address,
    :usdc_address,
    :deployed_block,
    :trait_table_hash
  ]

  @impl true
  def validate(%{data: %{contract_address: nil}}, _opts, _context), do: :ok

  def validate(changeset, _opts, _context) do
    if Enum.all?(
         @fields,
         &(Map.fetch!(changeset.data, &1) == Ash.Changeset.get_attribute(changeset, &1))
       ) do
      :ok
    else
      {:error, field: :contract_address, message: "fleet is already bound to another deployment"}
    end
  end
end
