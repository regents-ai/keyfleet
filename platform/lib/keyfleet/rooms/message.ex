defmodule KeyFleet.Rooms.Message do
  require Ash.Query

  @moduledoc """
  One line in one room, in the place that room gave it: a post a member wrote,
  or the note that a member named the room.

  Posts are never edited and never removed, so the table is the room's whole
  history and the place a post holds is the only thing a reader has to remember
  to carry on where it left off.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: KeyFleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @max_body 4_000
  @max_page 200

  postgres do
    table "messages"
    repo(KeyFleet.Repo)
    migration_defaults(inserted_at: "fragment(\"(clock_timestamp() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:seq, "messages_positive_seq", check: "seq > 0")

      # A post, or the line saying a member named the room.
      check_constraint(:kind, "messages_kind", check: "kind IN ('post', 'room_named')")

      check_constraint(:author_wallet, "messages_author_wallet_shape",
        check: "author_wallet ~ '^0x[0-9a-f]{40}$'"
      )

      check_constraint(:body, "messages_body_length",
        check: "length(body) BETWEEN 1 AND #{@max_body}"
      )
    end

    custom_statements do
      statement :immutable_messages_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_message() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
            RAISE EXCEPTION 'messages cannot be deleted' USING ERRCODE = '23514';
          END IF;
          RAISE EXCEPTION 'messages cannot be edited' USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_message();")
      end

      statement :immutable_messages_trigger do
        up("""
        CREATE TRIGGER immutable_messages BEFORE UPDATE OR DELETE ON keyfleet_app.messages
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_message();
        """)

        down("""
        DROP TRIGGER immutable_messages ON keyfleet_app.messages;
        """)
      end

      # Emptying the table is refused too; a row trigger never sees TRUNCATE.
      statement :untruncatable_messages_trigger do
        up("""
        CREATE TRIGGER untruncatable_messages BEFORE TRUNCATE ON keyfleet_app.messages
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.protect_message();
        """)

        down("""
        DROP TRIGGER untruncatable_messages ON keyfleet_app.messages;
        """)
      end
    end
  end

  actions do
    create :send_message do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false

      argument :body, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: @max_body, trim?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128, trim?: false]

      argument :reply_to_id, :uuid

      # The sender's own key settles a repeat: the database hands back the post
      # that key already made rather than taking a second place in the room.
      upsert? true
      upsert_identity :unique_send_key
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      validate KeyFleet.Graph.Validations.KnownFleet
      change {KeyFleet.Rooms.Changes.PostMessage, kind: :post}
      change KeyFleet.Rooms.Changes.AnnouncePost
    end

    # The line an open room takes when a member names it, written inside the
    # naming itself (`KeyFleet.Rooms.Changes.NameRoom`), which tells the room's
    # watchers once it commits. Its body is the room's new topic.
    create :note_room_named do
      public? false
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false

      argument :body, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: @max_body, trim?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128, trim?: false]

      change {KeyFleet.Rooms.Changes.PostMessage, kind: :room_named}
    end

    read :read_messages do
      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      argument :after_seq, :integer, default: 0, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: @max_page]

      validate KeyFleet.Graph.Validations.KnownFleet
      filter expr(seq > ^arg(:after_seq))

      prepare build(load: [:agent_profile])

      # One named room's posts, oldest first and never more than the reader asked
      # for, whatever a caller tried to add to the query. A name the fleet does
      # not have reads as a room with nothing in it.
      prepare fn query, context ->
        Ash.Query.before_action(query, fn query ->
          room =
            KeyFleet.Rooms.get_room!(
              Ash.Query.get_argument(query, :fleet_id),
              Ash.Query.get_argument(query, :slug),
              actor: context.actor
            )

          query =
            case room do
              nil -> Ash.Query.do_filter(query, false)
              %{id: room_id} -> Ash.Query.filter(query, room_id == ^room_id)
            end

          query
          |> Ash.Query.unset([:sort, :limit, :offset])
          |> Ash.Query.sort(seq: :asc)
          |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
        end)
      end
    end

    read :in_room do
      public? false
      argument :id, :uuid, allow_nil?: false
      argument :room_id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and room_id == ^arg(:room_id))
      get? true
    end

    read :under_send_key do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :author_wallet, :string, allow_nil?: false
      argument :idempotency_key, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and author_wallet == ^arg(:author_wallet) and
                 idempotency_key == ^arg(:idempotency_key)
             )

      get? true
    end
  end

  policies do
    # Spec section 7: room history is public to read, and posting is gated.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:send_message, :note_room_named]) do
      authorize_if KeyFleet.Rooms.Checks.RoomPoster
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :seq, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

    # A post a member wrote, or the note that a member named the room.
    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:post, :room_named]]

    attribute :author_kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:human, :agent]]

    attribute :author_wallet, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    attribute :body, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min_length: 1, max_length: @max_body, trim?: false]

    # The same words under the same send key are the same post; different words
    # are a mistake the sender is told about instead of a second post.
    attribute :body_digest, :string,
      allow_nil?: false,
      public?: false,
      writable?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/, trim?: false]

    attribute :idempotency_key, :string,
      allow_nil?: false,
      public?: false,
      writable?: false,
      constraints: [min_length: 1, max_length: 128, trim?: false]

    attribute :inserted_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :room, KeyFleet.Rooms.Room do
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :agent_profile, KeyFleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
      read_action :public_profile
    end

    belongs_to :reply_to, KeyFleet.Rooms.Message do
      attribute_writable? false
      public? true
    end
  end

  calculations do
    # The place of the post this one answers, which is always in the same room.
    calculate :reply_to_seq,
              :integer,
              expr(
                fragment(
                  "(SELECT answered.seq FROM keyfleet_app.messages AS answered WHERE answered.id = ?)",
                  reply_to_id
                )
              )
  end

  identities do
    identity :unique_place_in_room, [:room_id, :seq]
    identity :unique_send_key, [:fleet_id, :author_wallet, :idempotency_key]
  end
end
