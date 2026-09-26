defmodule Keyfleet.Fleets.Fleet do
  @moduledoc """
  A fixed fleet with a stable machine identity and display name, and once it is
  deployed, the chain and contracts it lives at, the USDC its keys are paid in,
  the asset registry it shares with every fleet on its chain and the hash of the
  trait table its keys' traits are drawn from.
  """
  use Ash.Resource,
    domain: Keyfleet.Fleets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "fleets"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:id, "fleets_fixed_catalog",
        check:
          "id IN ('fibonacci_syndicate', 'fibonacci_cascade', 'fleet_tech_classic', 'fleet_tech_accelerant')",
        message: "must identify one of the four fixed fleets"
      )

      # A deployment is recorded whole or not at all.
      check_constraint(:contract_address, "fleets_deployment_whole",
        check:
          "num_nulls(chain_id, contract_address, rewards_address, votes_address, usdc_address, asset_registry_address, deployed_block, trait_table_hash) IN (0, 8)",
        message: "must record the whole deployment"
      )

      for field <- [
            :contract_address,
            :rewards_address,
            :votes_address,
            :usdc_address,
            :asset_registry_address
          ] do
        check_constraint(field, "fleets_#{field}_shape", check: "#{field} ~ '^0x[0-9a-f]{40}$'")
      end

      check_constraint(:trait_table_hash, "fleets_trait_table_hash_shape",
        check: "trait_table_hash ~ '^0x[0-9a-f]{64}$'"
      )
    end
  end

  actions do
    defaults [:read]

    create :bootstrap do
      public? false
      accept [:id, :name]

      validate one_of(
                 :id,
                 ~w(fibonacci_syndicate fibonacci_cascade fleet_tech_classic fleet_tech_accelerant)
               )

      upsert? true
      upsert_fields [:name]
    end

    read :deployed do
      public? false
      filter expr(not is_nil(contract_address))
      prepare build(sort: [id: :asc])
    end

    # Binds the fleet to its deployment once. Recording the same deployment
    # again changes nothing; a different one is refused, and so is one whose
    # chain, USDC, asset registry or trait table differs from another bound
    # fleet's.
    update :record_deployment do
      public? false
      require_atomic? false

      accept [
        :chain_id,
        :contract_address,
        :rewards_address,
        :votes_address,
        :usdc_address,
        :asset_registry_address,
        :deployed_block,
        :trait_table_hash
      ]

      require_attributes [
        :chain_id,
        :contract_address,
        :rewards_address,
        :votes_address,
        :usdc_address,
        :asset_registry_address,
        :deployed_block,
        :trait_table_hash
      ]

      validate Keyfleet.Fleets.Validations.SameDeployment
      validate Keyfleet.Fleets.Validations.SharedWiring, before_action?: true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:bootstrap, :record_deployment]) do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :chain_id, :integer, public?: true, constraints: [min: 1]

    for field <- [
          :contract_address,
          :rewards_address,
          :votes_address,
          :usdc_address,
          :asset_registry_address
        ] do
      attribute field, :string,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]
    end

    # The first block of the deployment, where reading its history starts.
    attribute :deployed_block, :integer, public?: true, constraints: [min: 0]

    # `keccak256` of the trait table file, byte for byte, as the fleet holds it.
    attribute :trait_table_hash, :string,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]
  end
end
