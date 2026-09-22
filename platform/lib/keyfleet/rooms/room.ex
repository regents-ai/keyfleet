defmodule KeyFleet.Rooms.Room do
  @moduledoc "A core room with a stable identity within its fleet."
  use Ash.Resource,
    domain: KeyFleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "rooms"
    repo(KeyFleet.Repo)

    check_constraints do
      # `KeyFleet.Rooms.Sequence` moves this column with a statement of its own,
      # so the floor is kept where that statement cannot step over it.
      check_constraint(:head_seq, "rooms_nonnegative_head", check: "head_seq >= 0")
    end
  end

  actions do
    read :for_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [slug: :asc])
    end

    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and slug == ^arg(:slug))
      get? true
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
    policy action([:for_fleet, :in_fleet]) do
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

    # How many posts this room has taken, which is also the place the newest one
    # holds. Only `KeyFleet.Rooms.Sequence` moves it.
    attribute :head_seq, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: 0,
      constraints: [min: 0]
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
