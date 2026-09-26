defmodule Keyfleet.Fleets do
  @moduledoc "The fixed fleet catalog."
  use Ash.Domain

  alias Keyfleet.Fleets.Fleet

  # The fleets in the order the site shows them. Classic opens first; the
  # others show as coming soon until the founder opens them, one at a time,
  # by marking them `coming_soon?: false` here or by recording their
  # deployment.
  @catalog [
    %{id: "fleet_tech_classic", name: "Keyfleet Classic", coming_soon?: false},
    %{id: "fibonacci_syndicate", name: "Keyfleet Syndicate", coming_soon?: true},
    %{id: "fibonacci_cascade", name: "Keyfleet Cascade", coming_soon?: true},
    %{id: "fleet_tech_accelerant", name: "Keyfleet Accelerant", coming_soon?: true}
  ]

  resources do
    resource Keyfleet.Fleets.Fleet do
      define :list_fleets, action: :read
      define :get_fleet, action: :read, get_by: [:id], not_found_error?: false
      define :list_deployed_fleets, action: :deployed
      define :record_deployment, action: :record_deployment
    end
  end

  @doc """
  The fixed catalog's fleets as `%{id: id, name: name, coming_soon?: marked}`,
  in the order the site shows them. `coming_soon?` is the catalog's mark
  alone; `coming_soon?/2` says whether a fleet is coming soon.
  """
  def catalog, do: @catalog

  @doc "The machine ids of the fixed catalog, in catalog order."
  def catalog_ids, do: Enum.map(@catalog, & &1.id)

  @doc """
  Whether the fleet `fleet_id`, recorded as `recorded` (or `nil` before the
  catalog is seeded), is coming soon: the catalog marks it so and no
  deployment is recorded for it. A coming-soon fleet shows its name and that
  it is coming soon, and nothing else: no price, no keys, no rooms and no
  way to join. Recording its deployment by hand opens it.
  """
  def coming_soon?(fleet_id, recorded) do
    Enum.any?(@catalog, &(&1.id == fleet_id and &1.coming_soon?)) and
      (recorded == nil or recorded.contract_address == nil)
  end

  @doc "The ids of the fleets that are not coming soon, in catalog order."
  def open_fleet_ids do
    recorded = Map.new(list_fleets!(), &{&1.id, &1})
    for %{id: id} <- @catalog, not coming_soon?(id, recorded[id]), do: id
  end

  @doc """
  Seeds the fixed catalog from trusted application setup code.

  Reruns preserve machine identities and restore canonical display names. The
  whole catalog commits together. This internal entry point must never be exposed
  as a user action.
  """
  def bootstrap_catalog! do
    %Ash.BulkResult{records: fleets} =
      @catalog
      |> Enum.map(&Map.take(&1, [:id, :name]))
      |> Ash.bulk_create!(Fleet, :bootstrap,
        actor: %Keyfleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    fleets
  end

  # The deployed manifest names its fleet by its slot in the deployment.
  @manifest_slots %{
    "syndicate" => "fibonacci_syndicate",
    "cascade" => "fibonacci_cascade",
    "classic" => "fleet_tech_classic",
    "accelerant" => "fleet_tech_accelerant"
  }

  @doc "The fleet in a deployment's `slot`, such as `syndicate`, or `nil` for no such slot."
  def slot_fleet_id(slot), do: Map.get(@manifest_slots, slot)

  # What every deployed fleet shares with every other: they sell on one chain,
  # for one USDC, admit deposits through one asset registry and draw traits
  # from one trait table.
  @shared_wiring [:chain_id, :usdc_address, :asset_registry_address, :trait_table_hash]

  @doc """
  Binds one fleet to the deployment a deployed manifest describes, the JSON
  `contracts/script/RecordKeyfleets.s.sol` writes for one fleet, from trusted
  operator code, and returns the fleet.

  Recording the same manifest again changes nothing; a manifest naming other
  contracts for a bound fleet is refused, and so is one whose chain, USDC,
  asset registry or trait table differs from a fleet already bound. Every
  other fleet is left as it is.
  """
  def record_manifest!(%{
        "chainId" => chain_id,
        "deploymentBlock" => block,
        "usdc" => usdc,
        "assetRegistry" => asset_registry,
        "traitTableHash" => trait_table_hash,
        "fleet" => %{"slot" => slot, "address" => address, "rewards" => rewards, "votes" => votes}
      })
      when is_integer(chain_id) and is_integer(block) do
    bootstrap_catalog!()
    fleet_id = Map.fetch!(@manifest_slots, slot)

    deployment = %{
      chain_id: chain_id,
      contract_address: String.downcase(address),
      rewards_address: String.downcase(rewards),
      votes_address: String.downcase(votes),
      usdc_address: String.downcase(usdc),
      asset_registry_address: String.downcase(asset_registry),
      deployed_block: block,
      trait_table_hash: String.downcase(trait_table_hash)
    }

    require_shared_wiring!(fleet_id, Map.take(deployment, @shared_wiring))

    fleet_id
    |> get_fleet!()
    |> record_deployment!(deployment, actor: %Keyfleet.Actors.System{})
  end

  defp require_shared_wiring!(fleet_id, wiring) do
    for bound <- list_deployed_fleets!(),
        bound.id != fleet_id,
        field <- @shared_wiring,
        Map.fetch!(bound, field) != Map.fetch!(wiring, field) do
      raise "#{fleet_id} cannot be recorded: its #{field} differs from #{bound.id}'s"
    end

    :ok
  end
end
