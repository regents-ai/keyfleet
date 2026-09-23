defmodule KeyFleet.Fleets.Fleet do
  @moduledoc """
  A fixed fleet with a stable machine identity and display name, and once it is
  deployed, the chain and contracts it lives at and the USDC its keys are paid in.
  """
  use Ash.Resource,
    domain: KeyFleet.Fleets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "fleets"
    repo(KeyFleet.Repo)

    check_constraints do
      check_constraint(:id, "fleets_fixed_catalog",
        check:
          "id IN ('fibonacci_syndicate', 'fibonacci_cascade', 'fleet_tech_classic', 'fleet_tech_accelerant')",
        message: "must identify one of the four fixed fleets"
      )

      # A deployment is recorded whole or not at all.
      check_constraint(:contract_address, "fleets_deployment_whole",
        check:
          "num_nulls(chain_id, contract_address, rewards_address, votes_address, usdc_address, deployed_block) IN (0, 6)",
        message: "must record the whole deployment"
      )

      for field <- [:contract_address, :rewards_address, :votes_address, :usdc_address] do
        check_constraint(field, "fleets_#{field}_shape", check: "#{field} ~ '^0x[0-9a-f]{40}$'")
      end
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
    # again changes nothing; a different one is refused.
    update :record_deployment do
      public? false
      require_atomic? false

      accept [
        :chain_id,
        :contract_address,
        :rewards_address,
        :votes_address,
        :usdc_address,
        :deployed_block
      ]

      require_attributes [
        :chain_id,
        :contract_address,
        :rewards_address,
        :votes_address,
        :usdc_address,
        :deployed_block
      ]

      validate KeyFleet.Fleets.Validations.SameDeployment
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:bootstrap, :record_deployment]) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :chain_id, :integer, public?: true, constraints: [min: 1]

    for field <- [:contract_address, :rewards_address, :votes_address, :usdc_address] do
      attribute field, :string,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]
    end

    # The first block of the deployment, where reading its history starts.
    attribute :deployed_block, :integer, public?: true, constraints: [min: 0]
  end
end
