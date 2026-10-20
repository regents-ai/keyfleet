defmodule Keyfleet.Graph.Object do
  @moduledoc """
  One workspace object as the fleet's graph log last left it: its member
  fields (`data`), its server-owned fields (`sys`) and its version.

  A task marked done has been submitted for review, and its `review` says
  where that stands: `awaiting_review` until a review of the task's current
  version has been recorded, then `disputed` if any review of that version
  disputes it, otherwise `accepted`. Any change to the task makes a new
  version, which waits for review again.

  An object last changed where its creation or its latest patch (an archive
  included) stands in the log: `changed_seq` is that event's place and
  `changed_at` its time. Nothing else moves them: linking the object,
  unlinking it, or a notice that it needs attention leaves them as they were.

  Only the projector writes here. Only the fleet's members read its objects
  (`Keyfleet.Graph.Checks.KeyReader`), except through the three reads a fleet
  shows anyone: its open work, by title; the titles of the items its latest
  activity names, where anyone else reads only the goals'; and its outline,
  each goal and task by title, standing and public summary alone.
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
                load: [:title, :card, :review]
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
    # Anyone may read it, so each object comes with its title alone. Callers
    # bound it with a limit, or count it.
    read :open_work do
      argument :fleet_id, :string, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:goals_open, :tasks_doing, :tasks_taken, :tasks_untaken]]

      filter expr(fleet_id == ^arg(:fleet_id))
      prepare Keyfleet.Graph.Preparations.OpenWork

      prepare build(
                sort: [changed_seq: :desc],
                select: [:fleet_id, :id, :type, :changed_seq, :changed_at],
                load: [:title]
              )
    end

    # The fleet's goals or tasks, as `type` says, the most recently changed
    # first, archived ones left out. Anyone may read it, so each comes with
    # its title, its standing (a goal's status, a task's progress or, once
    # submitted, its review) and the public summary its members wrote, and
    # nothing else. Callers bound it with a limit, or ask for one by id.
    read :outline do
      argument :fleet_id, :string, allow_nil?: false

      argument :type, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A(goal|task)\z/, trim?: false]

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == ^arg(:type) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys)
             )

      prepare build(
                sort: [changed_seq: :desc],
                select: [:fleet_id, :id, :type, :changed_seq, :changed_at],
                load: [:title, :standing, :public_summary]
              )
    end

    # The evidence that cites `uri` as its source, the most recently changed
    # first, archived evidence included.
    read :citing do
      argument :fleet_id, :string, allow_nil?: false
      argument :uri, :string, allow_nil?: false, constraints: @text

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == "evidence" and
                 fragment("? ->> 'source_uri'", data) == ^arg(:uri)
             )

      prepare build(
                sort: [changed_seq: :desc],
                limit: 20,
                select: [:fleet_id, :id, :type, :sys, :changed_seq, :changed_at],
                load: [:title, :card]
              )
    end

    # The work around one goal that is still in the workspace, the most
    # recently changed first: every object linked to the goal either way, and
    # what the tasks that deliver on it produced. Each comes with what its card
    # shows. One more than a goal's page lists is read, to tell there are more.
    read :around_goal do
      argument :fleet_id, :string, allow_nil?: false
      argument :goal_id, :string, allow_nil?: false, constraints: @text

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 fragment(
                   """
                   ? IN (
                     SELECT link.source FROM keyfleet_app.graph_relations AS link
                     WHERE link.fleet_id = ? AND link.target = ?
                     UNION
                     SELECT link.target FROM keyfleet_app.graph_relations AS link
                     WHERE link.fleet_id = ? AND link.source = ?
                     UNION
                     SELECT made.target FROM keyfleet_app.graph_relations AS link
                     JOIN keyfleet_app.graph_relations AS made
                       ON made.fleet_id = link.fleet_id AND made.source = link.source
                         AND made.type = 'produces'
                     WHERE link.fleet_id = ? AND link.target = ? AND link.type = 'implements'
                   )
                   """,
                   id,
                   ^arg(:fleet_id),
                   ^arg(:goal_id),
                   ^arg(:fleet_id),
                   ^arg(:goal_id),
                   ^arg(:fleet_id),
                   ^arg(:goal_id)
                 ) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys)
             )

      prepare build(
                sort: [changed_seq: :desc],
                limit: 101,
                select: [:fleet_id, :id, :type, :sys, :changed_seq, :changed_at],
                load: [:title, :card, :standing]
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

    # The goals a Key and wallet of the fleet joined and that are still in the
    # workspace, newest change first.
    read :joined_by do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1]
      argument :wallet, :string, allow_nil?: false, constraints: @text

      filter expr(
               fleet_id == ^arg(:fleet_id) and type == "goal" and
                 fragment(
                   "(? -> 'joined') @> jsonb_build_array(jsonb_build_object('key', jsonb_build_object('token_id', ?::bigint), 'wallet', ?::text))",
                   sys,
                   ^arg(:token_id),
                   ^arg(:wallet)
                 ) and
                 fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys)
             )

      prepare build(
                sort: [changed_seq: :desc],
                limit: 20,
                select: [:fleet_id, :id, :type, :version],
                load: [:title, :card]
              )
    end

    # The titles of a few of the fleet's objects, to name the objects a page
    # mentions: every one for the fleet's members, the goals for anyone else.
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
    # The summary a fleet shows anyone.
    policy action([:open_work, :outline]) do
      authorize_if always()
    end

    # Anyone may read a goal's title; only the fleet's members read the
    # titles of its other items.
    policy action(:titled) do
      authorize_if expr(type == "goal")
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action([:in_fleet, :cards, :around_goal, :assigned_to_keys, :joined_by, :citing]) do
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action([:with_ids, :project]) do
      authorize_if actor_attribute_equals(:role, :system)
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
    # A review has no title of its own; it is named by its decision.
    calculate :title,
              :string,
              expr(
                fragment(
                  "left(CASE ? WHEN 'review' THEN CASE ? ->> 'decision' WHEN 'accept' THEN 'Review: accepted' WHEN 'dispute' THEN 'Review: disputed' END ELSE ? ->> 'title' END, 200)",
                  type,
                  data,
                  data
                )
              ),
              public?: true

    # Where a submitted task's review stands; nothing for any other object.
    # The reviews of a task are the `reviews` links to it, read through the
    # links' index on their target.
    calculate :review,
              :string,
              expr(
                fragment(
                  """
                  CASE WHEN ? = 'task' AND (? ->> 'progress') = 'done' THEN COALESCE((
                    SELECT CASE
                      WHEN bool_or((review.data ->> 'decision') = 'dispute') THEN 'disputed'
                      WHEN bool_or((review.data ->> 'decision') = 'accept') THEN 'accepted'
                    END
                    FROM keyfleet_app.graph_relations AS link
                    JOIN keyfleet_app.graph_objects AS review
                      ON review.fleet_id = link.fleet_id AND review.id = link.source
                    WHERE link.fleet_id = ? AND link.target = ? AND link.type = 'reviews'
                      AND (review.sys #>> '{review,task_version}')::bigint = ?
                  ), 'awaiting_review') END
                  """,
                  type,
                  data,
                  fleet_id,
                  id,
                  version
                )
              ),
              public?: true

    # A task's next step as its author wrote it; nothing for any other object.
    calculate :next_step, :string, expr(fragment("? ->> 'next_step'", data)), public?: true

    # A goal's status, a task's progress or, once it is submitted, its
    # review; nothing for any other object.
    calculate :standing,
              :string,
              expr(
                fragment(
                  "COALESCE(?, left(CASE ? WHEN 'goal' THEN ? ->> 'status' WHEN 'task' THEN ? ->> 'progress' END, 32))",
                  review,
                  type,
                  data,
                  data
                )
              ),
              public?: true

    # What a goal's or task's members wrote for anyone to read.
    calculate :public_summary,
              :string,
              expr(fragment("left(? ->> 'public_summary', 500)", data)),
              public?: true

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
                    'source_uri', left(? ->> 'source_uri', 512),
                    'gist', left(CASE ?
                      WHEN 'goal' THEN ? ->> 'outcome'
                      WHEN 'task' THEN COALESCE(? ->> 'next_step', ? ->> 'deliverable')
                      WHEN 'finding' THEN ? ->> 'statement'
                      WHEN 'evidence' THEN ? ->> 'excerpt'
                      WHEN 'service' THEN ? ->> 'problem'
                      WHEN 'note' THEN ? ->> 'body'
                      WHEN 'dead_end' THEN ? ->> 'why_it_failed'
                      WHEN 'review' THEN ? ->> 'rationale'
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
