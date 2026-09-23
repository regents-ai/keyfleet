defmodule KeyFleet.Graph.Object do
  @moduledoc """
  One workspace object as the fleet's graph log last left it: its member
  fields (`data`), its server-owned fields (`sys`) and its version.

  Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: KeyFleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @text [trim?: false]

  postgres do
    table "graph_objects"
    repo(KeyFleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
    end
  end

  actions do
    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false, constraints: @text
      filter expr(fleet_id == ^arg(:fleet_id) and id == ^arg(:id))
      get? true
    end

    read :with_ids do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :ids, {:array, :string}, allow_nil?: false, constraints: [items: @text]
      filter expr(fleet_id == ^arg(:fleet_id) and id in ^arg(:ids))
    end

    create :project do
      public? false
      accept [:fleet_id, :id, :type, :data, :sys, :version]
      upsert? true
      upsert_fields [:type, :data, :sys, :version]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:project) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: @text

    attribute :type, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :data, :map, allow_nil?: false, public?: true
    attribute :sys, :map, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
  end

  relationships do
    belongs_to :cursor, KeyFleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
    end
  end
end
