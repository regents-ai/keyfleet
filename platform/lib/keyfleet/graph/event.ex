defmodule Keyfleet.Graph.Event do
  @moduledoc """
  One event of a fleet's graph log, copied at its place (`seq`) in the log.

  Only the events that change the workspace, the attention each write asks
  for and the command record each write leaves are copied; the runtime's own
  bookkeeping is not. Each keeps
  `byte_size`, the length of the event as a reader receives it, so a page of
  events is cut to size by the database. Only the projector writes here. Only
  the fleet's members read its events (`Keyfleet.Graph.Checks.KeyReader`),
  except the lines of its latest activity a fleet shows anyone, which carry no
  text an event holds.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @bigint 9_223_372_036_854_775_807
  @text [trim?: false]
  # A page stops at this many bytes of events, or after its first event when
  # that one alone is larger.
  @page_bytes 512 * 1024
  # How many of the latest changes the workspace page lists.
  @activity 30
  # How many of one object's changes its page lists at a time.
  @history 50
  @brief_fields [:fleet_id, :seq, :type, :actor, :timestamp]
  @member ~r/\Amember:[0-9]+:0x[0-9a-f]{40}:([0-9]+)@[0-9]+\/(human|agent):(0x[0-9a-f]{40})\z/
  # How many of the latest notable events a featured change is looked for in.
  @marks_window 200

  # The changes worth telling people who watch a fleet: every new object; a
  # patch that moves a status, progress or who has taken a task, archives an
  # object, or changes a goal or service; and a link saying that
  # one object supports, contradicts or produces another. Edits to other
  # objects' words, unlinks, attention notices and command records are left
  # out. The same words make the partial index and the reads that use it, so
  # the index answers exactly the events that match.
  @notable """
  type = 'object.created' OR (type = 'relation.created' AND (payload #>> '{relation,type}') IN ('contradicts', 'supports', 'produces')) OR (type = 'patch.applied' AND (jsonb_exists_any(payload -> 'diff', ARRAY['status', 'progress', 'assignee_key']) OR (payload #> '{diff,sys,new,archived}') = 'true'::jsonb OR split_part(payload ->> 'target', '#', 1) IN ('goal', 'service')))\
  """

  # The oldest place in the fleet's latest 200 notable changes.
  @window_floor "COALESCE((SELECT w.seq FROM keyfleet_app.graph_events AS w WHERE w.fleet_id = ? AND (#{@notable}) ORDER BY w.seq DESC OFFSET ? LIMIT 1), 0)"

  postgres do
    table "graph_events"
    repo(Keyfleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
    end

    # The workspace pages find an object's events by the ids their payloads
    # name: an object's creation and links by `id`, its changes and links to
    # it by `target`, and links from it by `source`.
    custom_indexes do
      index(["fleet_id", "(payload ->> 'id')", "seq"], name: "graph_events_payload_id_index")

      index(["fleet_id", "(payload ->> 'target')", "seq"],
        name: "graph_events_payload_target_index"
      )

      index(["fleet_id", "(payload ->> 'source')", "seq"],
        name: "graph_events_payload_source_index"
      )

      # The fleet's notable changes, newest first, for its activity.
      index(["fleet_id", "seq DESC"], name: "graph_events_notable_index", where: @notable)
    end
  end

  actions do
    # The events after one place in the log, oldest first: at most `limit` of
    # them, and no more than `@page_bytes` of them unless the first alone is
    # larger. The cut is found from the recorded sizes inside the query, so
    # only the page's own rows are loaded.
    read :page do
      argument :fleet_id, :string, allow_nil?: false
      argument :after_seq, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 500]

      filter expr(
               fleet_id == ^arg(:fleet_id) and seq > ^arg(:after_seq) and
                 seq <=
                   fragment(
                     "(SELECT COALESCE(max(p.seq) FILTER (WHERE p.total <= ?), min(p.seq)) FROM (SELECT e.seq, sum(e.byte_size) OVER (ORDER BY e.seq) AS total FROM keyfleet_app.graph_events AS e WHERE e.fleet_id = ? AND e.seq > ? ORDER BY e.seq LIMIT ?) AS p)",
                     ^@page_bytes,
                     ^arg(:fleet_id),
                     ^arg(:after_seq),
                     ^arg(:limit)
                   )
             )

      prepare fn query, _context ->
        query
        |> Ash.Query.unset([:sort, :limit, :offset])
        |> Ash.Query.sort(seq: :asc)
        |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
      end
    end

    # The fleet's latest changes, newest first, for its workspace page. The
    # record each write leaves of itself is left out: the changes it made are
    # listed on their own.
    read :activity do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and type != "keyfleet.command")

      prepare fn query, _context ->
        query
        |> Ash.Query.unset([:sort, :limit, :offset])
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(@activity)
        |> Ash.Query.select(@brief_fields)
        |> Ash.Query.load(:brief)
      end
    end

    # The fleet's notable changes before `before_seq` (from the newest when
    # nil), newest first, `limit` at most, each with what a line about it
    # needs and not the text it carries.
    read :notable_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_seq, :integer, constraints: [min: 1, max: @bigint]
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 60]

      filter expr(fleet_id == ^arg(:fleet_id))

      prepare fn query, _context -> Ash.Query.filter(query, ^sql(@notable)) end
      prepare {Keyfleet.Preparations.NewestFirst, sort: [seq: :desc], before: [:before_seq]}
      prepare build(select: @brief_fields, load: [:brief])
    end

    # The latest disagreement (`:contradiction`, a `contradicts` link) or the
    # latest finished work (`:completion`, a goal achieved or a task done)
    # among the fleet's 200 latest notable changes, or none.
    read :latest_mark do
      argument :fleet_id, :string, allow_nil?: false

      argument :mark, :atom,
        allow_nil?: false,
        constraints: [one_of: [:contradiction, :completion]]

      filter expr(fleet_id == ^arg(:fleet_id))

      prepare fn query, _context ->
        fleet_id = Ash.Query.get_argument(query, :fleet_id)

        query
        |> Ash.Query.filter(^sql(@notable))
        |> Ash.Query.filter(seq >= ^sql(@window_floor, [fleet_id, @marks_window - 1]))
        |> mark(Ash.Query.get_argument(query, :mark))
        |> Ash.Query.unset([:sort, :limit, :offset])
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.select(@brief_fields)
        |> Ash.Query.load(:brief)
      end

      get? true
    end

    # Every change to one object up to `through_seq`, newest first, one more
    # than a page so the reader knows whether more come before: its creation,
    # its edits and archiving, and the links made to or from it and removed
    # again. Each kind of change is looked up on its own index and cut to that
    # many before they are merged, so a page reads only the object's own rows:
    # a removed link is found from each link the object ever had, one lookup
    # apiece, since a link is removed at most once.
    read :history do
      argument :fleet_id, :string, allow_nil?: false
      argument :object_id, :string, allow_nil?: false, constraints: @text

      argument :through_seq, :integer,
        allow_nil?: false,
        default: @bigint,
        constraints: [min: 0, max: @bigint]

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 fragment(
                   """
                   ? = ANY(ARRAY(
                     (SELECT e.seq FROM keyfleet_app.graph_events AS e
                      WHERE e.fleet_id = ? AND (e.payload ->> 'id') = ? AND e.type = 'object.created' AND e.seq <= ?
                      ORDER BY e.seq DESC LIMIT ?)
                     UNION ALL
                     (SELECT e.seq FROM keyfleet_app.graph_events AS e
                      WHERE e.fleet_id = ? AND (e.payload ->> 'target') = ? AND e.type IN ('patch.applied', 'relation.created') AND e.seq <= ?
                      ORDER BY e.seq DESC LIMIT ?)
                     UNION ALL
                     (SELECT e.seq FROM keyfleet_app.graph_events AS e
                      WHERE e.fleet_id = ? AND (e.payload ->> 'source') = ? AND e.type = 'relation.created' AND e.seq <= ?
                      ORDER BY e.seq DESC LIMIT ?)
                     UNION ALL
                     (SELECT d.seq
                      FROM keyfleet_app.graph_events AS r
                      CROSS JOIN LATERAL (
                        SELECT d.seq FROM keyfleet_app.graph_events AS d
                        WHERE d.fleet_id = r.fleet_id AND (d.payload ->> 'id') = (r.payload ->> 'id') AND d.type = 'relation.removed' AND d.seq > r.seq AND d.seq <= ?
                        LIMIT 1
                      ) AS d
                      WHERE r.fleet_id = ? AND r.type = 'relation.created' AND ((r.payload ->> 'source') = ? OR (r.payload ->> 'target') = ?)
                      ORDER BY d.seq DESC LIMIT ?)))
                   """,
                   seq,
                   ^arg(:fleet_id),
                   ^arg(:object_id),
                   ^arg(:through_seq),
                   ^(@history + 1),
                   ^arg(:fleet_id),
                   ^arg(:object_id),
                   ^arg(:through_seq),
                   ^(@history + 1),
                   ^arg(:fleet_id),
                   ^arg(:object_id),
                   ^arg(:through_seq),
                   ^(@history + 1),
                   ^arg(:through_seq),
                   ^arg(:fleet_id),
                   ^arg(:object_id),
                   ^arg(:object_id),
                   ^(@history + 1)
                 )
             )

      prepare build(
                sort: [seq: :desc],
                limit: @history + 1,
                select: @brief_fields,
                load: [:brief]
              )
    end

    create :record do
      public? false
      accept [:fleet_id, :seq, :event_id, :type, :actor, :timestamp, :payload]
      upsert? true
      upsert_fields [:event_id, :type, :actor, :timestamp, :payload, :byte_size]

      change fn changeset, _context ->
        encoded = changeset.attributes |> view() |> Jason.encode_to_iodata!()
        Ash.Changeset.force_change_attribute(changeset, :byte_size, IO.iodata_length(encoded))
      end
    end
  end

  policies do
    # The latest activity a fleet shows anyone.
    policy action([:notable_before, :latest_mark]) do
      authorize_if always()
    end

    policy action([:page, :activity, :history]) do
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action(:record) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :seq, :integer,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :event_id, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :type, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :actor, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :timestamp, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :payload, :map, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, constraints: [min: 1]
  end

  calculations do
    # What a line about the event needs from it, read in the database so a
    # page of lines never loads the text the event carries:
    #   object.created   object, object_type
    #   patch.applied    object, fields (the names changed), archived, joins
    #                    (members who joined the goal, less those who left)
    #                    and values: {old, new} of the few short fields shown
    #   relation.created relation_type, source, target
    #   relation.removed the same, from the event that made the link
    #   keyfleet.attention kind, object
    # Any other event answers an empty map.
    calculate :brief,
              :map,
              expr(
                fragment(
                  """
                  CASE ?
                  WHEN 'object.created' THEN jsonb_build_object('object', ? #>> '{object,id}', 'object_type', ? #>> '{object,type}')
                  WHEN 'patch.applied' THEN jsonb_build_object(
                    'object', (? ->> 'target'),
                    'fields', CASE WHEN jsonb_typeof(? -> 'diff') = 'object'
                      THEN (SELECT COALESCE(jsonb_agg(k.key ORDER BY k.key), '[]'::jsonb) FROM jsonb_object_keys(? -> 'diff') AS k(key))
                      ELSE '[]'::jsonb END,
                    'archived', COALESCE((? #> '{diff,sys,new,archived}') = 'true'::jsonb, false),
                    'joins', jsonb_array_length(COALESCE(? #> '{diff,sys,new,joined}', '[]'::jsonb)) - jsonb_array_length(COALESCE(? #> '{diff,sys,old,joined}', '[]'::jsonb)),
                    'values', jsonb_strip_nulls(jsonb_build_object(
                      'status', ? #> '{diff,status}',
                      'progress', ? #> '{diff,progress}',
                      'confidence', ? #> '{diff,confidence}',
                      'assignee_key', ? #> '{diff,assignee_key}')))
                  WHEN 'relation.created' THEN jsonb_build_object('relation_type', ? #>> '{relation,type}', 'source', (? ->> 'source'), 'target', (? ->> 'target'))
                  WHEN 'relation.removed' THEN
                    (SELECT jsonb_build_object('relation_type', r.payload #>> '{relation,type}', 'source', (r.payload ->> 'source'), 'target', (r.payload ->> 'target'))
                     FROM keyfleet_app.graph_events AS r
                     WHERE r.fleet_id = ? AND r.type = 'relation.created' AND (r.payload ->> 'id') = (? ->> 'id')
                     ORDER BY r.seq DESC LIMIT 1)
                  WHEN 'keyfleet.attention' THEN jsonb_build_object('kind', ? ->> 'kind', 'object', ? ->> 'object_id')
                  ELSE '{}'::jsonb
                  END
                  """,
                  type,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  payload,
                  fleet_id,
                  payload,
                  payload,
                  payload
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

  # A fragment of SQL kept in one module attribute, so the same words can
  # make an index and the reads that use it; the expression macro takes only
  # literal SQL.
  defp sql(sql, args \\ []) do
    {:ok, fragment} = Ash.Query.Function.Fragment.new([sql | args])
    fragment
  end

  defp mark(query, :contradiction) do
    Ash.Query.filter(
      query,
      type == "relation.created" and
        fragment("(? #>> '{relation,type}') = 'contradicts'", payload)
    )
  end

  defp mark(query, :completion) do
    Ash.Query.filter(
      query,
      type == "patch.applied" and
        fragment(
          "((split_part(? ->> 'target', '#', 1) = 'goal' AND (? #>> '{diff,status,new}') = 'achieved') OR (split_part(? ->> 'target', '#', 1) = 'task' AND (? #>> '{diff,progress,new}') = 'done'))",
          payload,
          payload,
          payload,
          payload
        )
    )
  end

  @doc """
  The member an event's `actor` names, as `{token_id, kind, wallet}`: the Key
  it wrote as, `"human"` or `"agent"`, and the wallet that signed; nil for
  the workspace's own doing.
  """
  def member(actor) do
    case Regex.run(@member, actor, capture: :all_but_first) do
      [token_id, kind, wallet] -> {String.to_integer(token_id), kind, wallet}
      nil -> nil
    end
  end

  @doc "The event as a reader receives it."
  def view(event) do
    %{
      seq: event.seq,
      id: event.event_id,
      type: event.type,
      actor: event.actor,
      timestamp: event.timestamp,
      payload: event.payload
    }
  end
end
