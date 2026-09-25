defmodule Keyfleet.Graph.Relation do
  @moduledoc """
  One live link between two workspace objects, as the fleet's graph log last
  left it. A removed link has no row.

  Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @text [trim?: false]

  postgres do
    table "graph_relations"
    repo(Keyfleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
      # An object id is only unique within its fleet; these relationships
      # match the fleet too, so they have no foreign key of their own.
      reference(:source_object, ignore?: true)
      reference(:target_object, ignore?: true)
    end

    custom_indexes do
      index([:fleet_id, :source])
      # The links to an object, and those of one type the newest first.
      index([:fleet_id, :target, :type, :created_seq])
      # A fleet's links of one type, the newest first.
      index([:fleet_id, :type, :created_seq])
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

    # Links of one type from objects of one type, the newest first, each with
    # its source still in the workspace. Read by loading an object's
    # `links_in`, which names the object they point at.
    read :into do
      public? false
      argument :type, :string, allow_nil?: false, constraints: @text
      argument :source_type, :string, allow_nil?: false, constraints: @text

      filter expr(
               type == ^arg(:type) and source_object.type == ^arg(:source_type) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", source_object.sys)
             )

      prepare build(
                sort: [created_seq: :desc],
                select: [:fleet_id, :id, :type, :source, :target, :created_seq]
              )
    end

    # The fleet's newest links of one type between objects still in the
    # workspace: a link from or to an archived object is left out.
    read :of_type do
      argument :fleet_id, :string, allow_nil?: false
      argument :type, :string, allow_nil?: false, constraints: @text
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 50]

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == ^arg(:type) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", source_object.sys) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", target_object.sys)
             )

      prepare fn query, _context ->
        query
        |> Ash.Query.unset([:sort, :limit, :offset])
        |> Ash.Query.sort(created_seq: :desc)
        |> Ash.Query.select([:fleet_id, :id, :type, :source, :target, :created_seq])
        |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
      end
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
      authorize_if Keyfleet.Checks.SystemActor
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
    attribute :created_seq, Keyfleet.Graph.Seq, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :cursor, Keyfleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
    end

    belongs_to :source_object, Keyfleet.Graph.Object do
      source_attribute :source
      destination_attribute :id
      define_attribute? false
      read_action :link_end
      filter expr(fleet_id == parent(fleet_id))
    end

    belongs_to :target_object, Keyfleet.Graph.Object do
      source_attribute :target
      destination_attribute :id
      define_attribute? false
      read_action :link_end
      filter expr(fleet_id == parent(fleet_id))
    end
  end
end
