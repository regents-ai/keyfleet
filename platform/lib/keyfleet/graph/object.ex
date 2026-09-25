defmodule Keyfleet.Graph.Object do
  @moduledoc """
  One workspace object as the fleet's graph log last left it: its member
  fields (`data`), its server-owned fields (`sys`) and its version.

  An object last changed where its creation or its latest patch (an archive
  included) stands in the log: `changed_seq` is that event's place and
  `changed_at` its time. Nothing else moves them: linking the object,
  unlinking it, or a notice that it needs attention leaves them as they were.

  Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @text [trim?: false]

  postgres do
    table "graph_objects"
    repo(Keyfleet.Repo)

    # The workspace lists a fleet's objects, or one type of them, most
    # recently changed first.
    custom_indexes do
      index([:fleet_id, :changed_seq, :id], name: "graph_objects_changed_index")
      index([:fleet_id, :type, :changed_seq, :id], name: "graph_objects_type_changed_index")
    end

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

    # A page of the fleet's workspace, the most recently changed first:
    # optionally one type of object only, and the archived ones only when
    # asked for. Each object comes with what its card shows, not its text.
    read :cards do
      argument :fleet_id, :string, allow_nil?: false
      argument :type, :string, constraints: @text
      argument :include_archived?, :boolean, allow_nil?: false, default: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 (is_nil(^arg(:type)) or type == ^arg(:type)) and
                 (^arg(:include_archived?) or
                    fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys))
             )

      prepare build(
                sort: [changed_seq: :desc],
                select: [:fleet_id, :id, :type, :sys, :version, :changed_seq, :changed_at],
                load: [:title, :card]
              )

      # Ties, which the log never makes, break the way the index reads back.
      pagination keyset?: true,
                 required?: true,
                 default_limit: 24,
                 max_page_size: 24,
                 stable_sort: [fleet_id: :desc, id: :desc]
    end

    # The titles of a few of the fleet's objects, to name the objects a page
    # mentions.
    read :titled do
      argument :fleet_id, :string, allow_nil?: false

      argument :ids, {:array, :string},
        allow_nil?: false,
        constraints: [items: @text, max_length: 200]

      filter expr(fleet_id == ^arg(:fleet_id) and id in ^arg(:ids))
      prepare build(select: [:fleet_id, :id, :type, :sys], load: [:title])
    end

    read :with_ids do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :ids, {:array, :string}, allow_nil?: false, constraints: [items: @text]
      filter expr(fleet_id == ^arg(:fleet_id) and id in ^arg(:ids))
    end

    create :project do
      public? false
      accept [:fleet_id, :id, :type, :data, :sys, :version, :changed_seq, :changed_at]
      upsert? true
      upsert_fields [:type, :data, :sys, :version, :changed_seq, :changed_at]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:project) do
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
    attribute :data, :map, allow_nil?: false, public?: true
    attribute :sys, :map, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :changed_seq, Keyfleet.Graph.Seq, allow_nil?: false, public?: true

    attribute :changed_at, :string, allow_nil?: false, public?: true, constraints: @text
  end

  calculations do
    calculate :title, :string, expr(fragment("left(? ->> 'title', 200)", data)), public?: true

    # The few short fields a card shows, and the start of the object's main
    # text, cut in the database so a page of cards never loads whole texts.
    calculate :card,
              :map,
              expr(
                fragment(
                  """
                  jsonb_strip_nulls(jsonb_build_object(
                    'status', left(? ->> 'status', 32),
                    'progress', left(? ->> 'progress', 32),
                    'assignee_key', ? -> 'assignee_key',
                    'confidence', left(? ->> 'confidence', 32),
                    'customer', left(? ->> 'customer', 200),
                    'payment_asset', left(? ->> 'payment_asset', 32),
                    'price_proposal', left(? ->> 'price_proposal', 100),
                    'name', left(? ->> 'name', 64),
                    'symbol', left(? ->> 'symbol', 16),
                    'source_uri', left(? ->> 'source_uri', 512),
                    'gist', left(CASE ?
                      WHEN 'goal' THEN ? ->> 'outcome'
                      WHEN 'task' THEN COALESCE(? ->> 'next_step', ? ->> 'deliverable')
                      WHEN 'finding' THEN ? ->> 'statement'
                      WHEN 'evidence' THEN ? ->> 'excerpt'
                      WHEN 'service' THEN ? ->> 'problem'
                      WHEN 'launch_card' THEN COALESCE(? ->> 'what_we_sell', ? ->> 'narrative')
                      WHEN 'note' THEN ? ->> 'body'
                    END, 240)))
                  """,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  type,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data,
                  data
                )
              ),
              public?: true
  end

  relationships do
    belongs_to :cursor, Keyfleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
    end
  end
end
