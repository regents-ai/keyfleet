defmodule Keyfleet.Polls.Event do
  @moduledoc """
  One line of a session's log, in the place the session gave it
  (`Keyfleet.Polls.Log`): a seat taken or given up, a round opened or closed,
  a suggestion in a delegate session, or the session ending. Lines are never
  changed or removed, so the place a reader last saw is all it needs to read
  on.

  Each line is announced on `Keyfleet.Polls.topic/1` as "poll_event" once its
  transaction commits. The announcement is only a nudge: a reader always reads
  the lines themselves.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Polls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @bigint 9_223_372_036_854_775_807
  @kinds [:seat_joined, :seat_left, :round_opened, :suggestion, :round_closed, :session_ended]

  postgres do
    table "poll_events"
    repo(Keyfleet.Repo)

    references do
      reference(:session, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:seq, "poll_events_positive_seq", check: "seq > 0")
    end

    custom_statements do
      statement :poll_events_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_poll_event() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'poll log lines cannot be changed or deleted' USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_poll_event();")
      end

      statement :poll_events_trigger do
        up("""
        CREATE TRIGGER protect_poll_events BEFORE UPDATE OR DELETE ON keyfleet_app.poll_events
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_poll_event();
        """)

        down("DROP TRIGGER protect_poll_events ON keyfleet_app.poll_events;")
      end
    end
  end

  actions do
    create :append do
      public? false
      accept [:session_id, :seq, :kind, :payload]
    end

    read :after do
      argument :fleet_id, :string, allow_nil?: false
      argument :session_id, :uuid, allow_nil?: false
      argument :after_seq, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: 200]

      filter expr(session_id == ^arg(:session_id) and seq > ^arg(:after_seq))
      prepare build(sort: [seq: :asc], limit: arg(:limit))
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "poll"
    broadcast_type :phoenix_broadcast

    publish :append, [:session_id], event: "poll_event", transform: &%{seq: &1.data.seq}
  end

  policies do
    policy action(:append) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:after) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :seated}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :seq, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :kind, :atom, allow_nil?: false, public?: true, constraints: [one_of: @kinds]
    attribute :payload, :map, allow_nil?: false, public?: true

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :session, Keyfleet.Polls.Session do
      attribute_writable? true
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_place, [:session_id, :seq]
  end
end
