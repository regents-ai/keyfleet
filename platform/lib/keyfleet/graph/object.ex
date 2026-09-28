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

    # The work still open in the fleet's workspace, the most recently changed
    # first: its open goals, the tasks in progress or the tasks nobody has
    # taken yet, as `kind` says (`Keyfleet.Graph.Preparations.OpenWork`).
    # Each object comes with what its card shows, not its text. Callers bound
    # it with a limit, or count it.
    read :open_work do
      argument :fleet_id, :string, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:goals_open, :tasks_doing, :tasks_taken, :tasks_untaken]]

      filter expr(fleet_id == ^arg(:fleet_id))
      prepare Keyfleet.Graph.Preparations.OpenWork

      prepare build(
                sort: [changed_seq: :desc],
                select: [:fleet_id, :id, :type, :sys, :version, :changed_seq, :changed_at],
                load: [:title, :card]
              )
    end

    # The unfinished tasks taken by these keys of the fleet, newest change
    # first, each with what its card shows.
    read :assigned_to_keys do
      argument :fleet_id, :string, allow_nil?: false

      argument :token_ids, {:array, :integer},
        allow_nil?: false,
        constraints: [max_length: 100, items: [min: 1]]

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == "task" and
                 fragment("(? ->> 'assignee_key')::bigint = ANY(?)", data, ^arg(:token_ids)) and
                 fragment("(? ->> 'progress') <> 'done'", data) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys)
             )

      prepare build(
                sort: [changed_seq: :desc],
                limit: 20,
                select: [:fleet_id, :id, :type, :version],
                load: [:title, :card, :next_step]
              )
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

    # The fleet's launch plans a launch can be proposed from: those not
    # archived whose six launch details are all filled in, the most recently
    # changed first.
    read :launch_plans do
      argument :fleet_id, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == "launch_card" and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys) and
                 fragment(
                   "(? ->> 'name') <> '' AND (? ->> 'symbol') <> '' AND (? ->> 'description') <> '' AND (? ->> 'website') <> '' AND (? ->> 'image') <> '' AND (? ->> 'required_regent_raised') <> ''",
                   data,
                   data,
                   data,
                   data,
                   data,
                   data
                 )
             )

      prepare build(
                sort: [changed_seq: :desc],
                select: [:fleet_id, :id, :version],
                limit: 24
              )
    end

    # What a link's relationships to its two ends read through.
    read :link_end do
      public? false
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

    # A task's next step as its author wrote it; nothing for any other object.
    calculate :next_step, :string, expr(fragment("? ->> 'next_step'", data)), public?: true

    # A goal's first open question, the one it most needs answered.
    calculate :first_open_question,
              :string,
              expr(fragment("left(? #>> '{open_questions,0}', 500)", data)),
              public?: true

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
                      WHEN 'dead_end' THEN ? ->> 'why_it_failed'
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

    # The links of one type that point at this object, read with the
    # relation's `:into` read.
    has_many :links_in, Keyfleet.Graph.Relation do
      source_attribute :id
      destination_attribute :target
      read_action :into
      filter expr(fleet_id == parent(fleet_id))
    end
  end
end
