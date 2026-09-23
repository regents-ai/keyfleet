defmodule KeyFleet.Graph.Relation do
  @moduledoc """
  One live link between two workspace objects, as the fleet's graph log last
  left it. A removed link has no row.

  Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: KeyFleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @text [trim?: false]

  postgres do
    table "graph_relations"
    repo(KeyFleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
    end

    custom_indexes do
      index([:fleet_id, :source])
      index([:fleet_id, :target])
    end
  end

  actions do
    # The links from or to one object, oldest first.
    read :touching do
      argument :fleet_id, :string, allow_nil?: false
      argument :object_id, :string, allow_nil?: false, constraints: @text
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 201]

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 (source == ^arg(:object_id) or target == ^arg(:object_id))
             )

      prepare fn query, _context ->
        query
        |> Ash.Query.unset([:sort, :limit, :offset])
        |> Ash.Query.sort(created_seq: :asc)
        |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
      end
    end

    # The links from or to one object a page at a time, oldest first.
    read :linked do
      argument :fleet_id, :string, allow_nil?: false
      argument :object_id, :string, allow_nil?: false, constraints: @text

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 (source == ^arg(:object_id) or target == ^arg(:object_id))
             )

      prepare build(sort: [created_seq: :asc])
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 50
    end

    read :with_ids do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :ids, {:array, :string}, allow_nil?: false, constraints: [items: @text]
      filter expr(fleet_id == ^arg(:fleet_id) and id in ^arg(:ids))
    end

    create :project do
      public? false
      accept [:fleet_id, :id, :type, :source, :target, :data, :created_seq]
      upsert? true
      upsert_fields [:type, :source, :target, :data, :created_seq]
    end

    destroy :remove do
      public? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:project, :remove]) do
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
    attribute :source, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :target, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :data, :map, allow_nil?: false, public?: true

    # The place in the log where the link was made.
    attribute :created_seq, KeyFleet.Graph.Seq, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :cursor, KeyFleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
    end
  end
end
