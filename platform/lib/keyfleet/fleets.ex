defmodule Keyfleet.Fleets do
  @moduledoc "The fixed fleet catalog."
  use Ash.Domain

  alias Keyfleet.Fleets.Fleet

  @catalog [
    %{id: "fibonacci_syndicate", name: "Keyfleet Syndicate"},
    %{id: "fibonacci_cascade", name: "Keyfleet Cascade"},
    %{id: "fleet_tech_classic", name: "Keyfleet Classic"},
    %{id: "fleet_tech_accelerant", name: "Keyfleet Accelerant"}
  ]

  resources do
    resource Keyfleet.Fleets.Fleet do
      define :list_fleets, action: :read
      define :get_fleet, action: :read, get_by: [:id], not_found_error?: false
      define :list_deployed_fleets, action: :deployed
      define :record_deployment, action: :record_deployment
    end
  end

  @doc "The fixed catalog's fleets as `%{id: id, name: name}`, in catalog order."
  def catalog, do: @catalog

  @doc "The machine ids of the fixed catalog, in catalog order."
  def catalog_ids, do: Enum.map(@catalog, & &1.id)

  @doc """
  Seeds the fixed catalog from trusted application setup code.

  Reruns preserve machine identities and restore canonical display names. The
  whole catalog commits together. This internal entry point must never be exposed
  as a user action.
  """
  def bootstrap_catalog! do
    %Ash.BulkResult{records: fleets} =
      Ash.bulk_create!(@catalog, Fleet, :bootstrap,
        actor: %Keyfleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    fleets
  end

  # The deployed manifest names each fleet by its slot in the deployment.
  @manifest_slots %{
    "syndicate" => "fibonacci_syndicate",
    "cascade" => "fibonacci_cascade",
    "classic" => "fleet_tech_classic",
    "accelerant" => "fleet_tech_accelerant"
  }

  @doc "The fleet in a deployment's `slot`, such as `syndicate`, or `nil` for no such slot."
  def slot_fleet_id(slot), do: Map.get(@manifest_slots, slot)

  @doc """
  Binds the four fleets to the deployment described by a deployed manifest,
  the JSON `contracts/script/RecordKeyfleets.s.sol` writes, from trusted
  operator code.

  All four are bound together or none is. Recording the same manifest again
  changes nothing; a manifest naming other contracts for a bound fleet is
  refused.
  """
  def record_deployments!(%{
        "chainId" => chain_id,
        "deploymentBlock" => block,
        "usdc" => usdc,
        "traitTableHash" => trait_table_hash,
        "fleets" => fleets
      })
      when is_integer(chain_id) and is_integer(block) do
    bootstrap_catalog!()

    {:ok, recorded} =
      Ash.transact(Fleet, fn ->
        for {slot, fleet_id} <- @manifest_slots do
          %{"address" => address, "rewards" => rewards, "votes" => votes} =
            Map.fetch!(fleets, slot)

          fleet_id
          |> get_fleet!()
          |> record_deployment!(
            %{
              chain_id: chain_id,
              contract_address: String.downcase(address),
              rewards_address: String.downcase(rewards),
              votes_address: String.downcase(votes),
              usdc_address: String.downcase(usdc),
              deployed_block: block,
              trait_table_hash: String.downcase(trait_table_hash)
            },
            actor: %Keyfleet.Actors.System{}
          )
        end
      end)

    Enum.sort_by(recorded, & &1.id)
  end
end
