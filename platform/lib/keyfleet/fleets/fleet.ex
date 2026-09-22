defmodule KeyFleet.Fleets.Fleet do
  @moduledoc "A fixed fleet with a stable machine identity and display name."
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
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :name, :string, allow_nil?: false, public?: true
  end
end
