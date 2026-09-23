defmodule KeyFleet.Graph.Event do
  @moduledoc """
  One event of a fleet's graph log, copied at its place (`seq`) in the log.

  Only the events that change the workspace, the attention each write asks
  for and the command record each write leaves are copied; the runtime's own
  bookkeeping is not. Each keeps
  `byte_size`, the length of the event as a reader receives it, so a page of
  events is cut to size by the database. Only the projector writes here;
  anyone may read.
  """
  use Ash.Resource,
    domain: KeyFleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @text [trim?: false]
  # A page stops at this many bytes of events, or after its first event when
  # that one alone is larger.
  @page_bytes 512 * 1024

  postgres do
    table "graph_events"
    repo(KeyFleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
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
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if KeyFleet.Checks.SystemActor
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

  relationships do
    belongs_to :cursor, KeyFleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
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
