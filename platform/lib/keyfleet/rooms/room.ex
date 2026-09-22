defmodule KeyFleet.Rooms.Room do
  @moduledoc "A core room with a stable identity within its fleet."
  use Ash.Resource,
    domain: KeyFleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "rooms"
    repo(KeyFleet.Repo)
  end

  actions do
    read :for_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [slug: :asc])
    end

    create :bootstrap do
      public? false
      accept [:fleet_id, :slug, :name]
      validate one_of(:slug, ["general", "planning", "work"])
      upsert? true
      upsert_identity :unique_slug_per_fleet
      upsert_fields [:name]
    end
  end

  policies do
    policy action(:for_fleet) do
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_slug_per_fleet, [:fleet_id, :slug]
  end
end
