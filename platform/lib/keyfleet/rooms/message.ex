defmodule Keyfleet.Rooms.Message do
  require Ash.Query

  @moduledoc """
  One line in one room, in the place that room gave it: a post a member wrote,
  or the note that a member named the room. A key's thread is a room too, so a
  post written to a key is a line in its thread.

  Every line is written as a key: the author's highest-ranked key in the fleet
  at the time (`Keyfleet.Keys.identity/2`), kept as `as_key`.

  Posts are never edited and never removed, so the table is the room's whole
  history and the place a post holds is the only thing a reader has to remember
  to carry on where it left off.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @bigint 9_223_372_036_854_775_807
  @max_body 4_000
  @max_page 200
  @max_posts_as_key 20
  @max_recent_in_fleet 10

  postgres do
    table "messages"
    repo(Keyfleet.Repo)
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

      # Every line names the key it was written as. Added without checking the
      # lines already written, which can never be changed.
      check_constraint(:as_key, "messages_as_key", check: "as_key IS NOT NULL AND as_key > 0")
    end

    custom_indexes do
      # A key's newest posts in the fleet's rooms.
      index(["fleet_id", "as_key", "inserted_at DESC"],
        name: "messages_posts_as_key_index",
        where: "kind = 'post' AND NOT in_key_thread"
      )

      # The fleet's newest lines across its rooms, without keys' threads.
      index(["fleet_id", "inserted_at DESC", "id"],
        name: "messages_fleet_lines_index",
        where: "NOT in_key_thread"
      )

      # One room's newest lines, without keys' threads: what the fleet's
      # lines are to anyone without one of its keys, who reads only General.
      index(["fleet_id", "room_id", "inserted_at DESC", "id"],
        name: "messages_fleet_room_lines_index",
        where: "NOT in_key_thread"
      )

      # Each room's naming lines, counted to tell its posts from its lines.
      index(["room_id"], name: "messages_room_namings_index", where: "kind = 'room_named'")
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

      validate Keyfleet.Graph.Validations.KnownFleet
      change {Keyfleet.Rooms.Changes.PostMessage, kind: :post, in: :room}
      change Keyfleet.Agents.Changes.NoteContribution
    end

    # A post written to one of the fleet's keys, in that key's thread, which
    # the first post opens. Otherwise the same as posting in a room.
    create :send_to_key do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      argument :body, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: @max_body, trim?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128, trim?: false]

      argument :reply_to_id, :uuid

      upsert? true
      upsert_identity :unique_send_key
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      validate Keyfleet.Graph.Validations.KnownFleet
      validate Keyfleet.Rooms.Validations.IssuedKey
      change {Keyfleet.Rooms.Changes.PostMessage, kind: :post, in: :key}
      change Keyfleet.Agents.Changes.NoteContribution
    end

    # The line an open room takes when a member names it, written inside the
    # naming itself (`Keyfleet.Rooms.Changes.NameRoom`), so the room's watchers
    # hear of it once the naming commits. Its body is the room's new topic.
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

      change {Keyfleet.Rooms.Changes.PostMessage, kind: :room_named, in: :room}
    end

    # A room's naming lines, when a room's posts are counted.
    read :read do
      primary? true
      public? false
    end

    read :read_messages do
      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      argument :after_seq, :integer, default: 0, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: @max_page]

      validate Keyfleet.Graph.Validations.KnownFleet
      filter expr(seq > ^arg(:after_seq))

      prepare build(load: [:agent_profile, :via_agent_profile])
      prepare {Keyfleet.Rooms.Preparations.OneRoom, in: :room}
      metadata :more_after, :boolean, allow_nil?: false
    end

    # The posts written to one of the fleet's keys, read the way a room is.
    read :read_key_thread do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :after_seq, :integer, default: 0, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: @max_page]

      validate Keyfleet.Graph.Validations.KnownFleet
      validate Keyfleet.Rooms.Validations.IssuedKey
      filter expr(seq > ^arg(:after_seq))

      prepare build(load: [:agent_profile, :via_agent_profile])
      prepare {Keyfleet.Rooms.Preparations.OneRoom, in: :key}
      metadata :more_after, :boolean, allow_nil?: false
    end

    # What one key has said in the fleet's rooms, newest first. Posts written
    # to keys' threads are left out.
    read :posts_as_key do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      argument :limit, :integer,
        default: @max_posts_as_key,
        constraints: [min: 1, max: @max_posts_as_key]

      filter expr(
               kind == :post and fleet_id == ^arg(:fleet_id) and as_key == ^arg(:token_id) and
                 not in_key_thread
             )

      prepare build(load: [:room, :agent_profile, :via_agent_profile])

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [inserted_at: :desc, id: :asc], before: []}
    end

    # The fleet's newest posts in its rooms, newest first, for the fleet
    # directory. Posts written to keys' threads are left out.
    read :recent_in_fleet do
      argument :fleet_id, :string, allow_nil?: false

      argument :limit, :integer,
        default: @max_recent_in_fleet,
        constraints: [min: 1, max: @max_recent_in_fleet]

      filter expr(kind == :post and fleet_id == ^arg(:fleet_id) and not in_key_thread)

      prepare build(load: [:room, :agent_profile, :via_agent_profile])

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [inserted_at: :desc, id: :asc], before: []}
    end

    # The fleet's lines in its rooms older than one line, newest first, for
    # the fleet's activity: posts and namings, without the posts written to
    # keys' threads. Ties in time come in id order. Each line comes with its
    # room and author but only the start of its words. It reads the fleet's
    # lines index (`messages_fleet_lines_index`) from the given line down, or
    # General's (`messages_fleet_room_lines_index`) for anyone without a key.
    read :fleet_lines_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_at, :utc_datetime_usec
      argument :before_id, :uuid
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: @max_page]

      filter expr(fleet_id == ^arg(:fleet_id) and not in_key_thread)

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [inserted_at: :desc, id: :asc], before: [:before_at, :before_id]}

      prepare build(
                select: [
                  :id,
                  :fleet_id,
                  :room_id,
                  :kind,
                  :author_kind,
                  :as_key,
                  :agent_profile_id,
                  :via_agent_profile_id,
                  :inserted_at
                ],
                load: [:excerpt, :room, :agent_profile, :via_agent_profile]
              )
    end

    # Every post one key has written in the fleet's rooms, for counting them.
    read :room_posts_as_key do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      filter expr(
               kind == :post and fleet_id == ^arg(:fleet_id) and as_key == ^arg(:token_id) and
                 not in_key_thread
             )
    end

    # Every post one person's wallet has written in the fleet's rooms, for
    # counting them.
    read :room_posts_by_wallet do
      argument :fleet_id, :string, allow_nil?: false
      argument :wallet, :string, allow_nil?: false

      filter expr(
               kind == :post and author_kind == :human and fleet_id == ^arg(:fleet_id) and
                 author_wallet == ^arg(:wallet) and not in_key_thread
             )
    end

    read :in_room do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :uuid, allow_nil?: false
      argument :room_id, :uuid, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and id == ^arg(:id) and room_id == ^arg(:room_id))
      get? true
    end

    # The first post a sender made under a send key from any of its wallets, so
    # a person's retry is known whichever of their wallets now holds the key
    # they write as.
    read :under_send_key do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :author_wallets, {:array, :string}, allow_nil?: false
      argument :idempotency_key, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and author_wallet in ^arg(:author_wallets) and
                 idempotency_key == ^arg(:idempotency_key)
             )

      prepare build(sort: [inserted_at: :asc, id: :asc], limit: 1)
      get? true
    end
  end

  # Delivered after the transaction commits, as `%Phoenix.Socket.Broadcast{}`
  # on `Keyfleet.Rooms.fleet_topic/1`: "room_head" with `%{room_id, seq}` for
  # every new line, and "key_activity" with `%{fleet_id, token_ids}` for a new
  # post, naming the key it was written as and the key whose thread it went to.
  # A repeat the database handed back is not announced. Best effort: anyone
  # reading a room reads it from the room itself.
  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "fleet"
    broadcast_type :phoenix_broadcast
    filter &(!Ash.Resource.get_metadata(&1.data, :upsert_skipped))

    publish_all :create, [:fleet_id, "rooms"],
      event: "room_head",
      transform: &%{room_id: &1.data.room_id, seq: &1.data.seq}

    publish :send_message, [:fleet_id, "rooms"],
      event: "key_activity",
      transform: &Keyfleet.Rooms.Message.key_activity/1

    publish :send_to_key, [:fleet_id, "rooms"],
      event: "key_activity",
      transform: &Keyfleet.Rooms.Message.key_activity/1
  end

  @doc false
  def key_activity(%{data: message, changeset: changeset}) do
    token_ids = Enum.uniq([message.as_key, Ash.Changeset.get_argument(changeset, :token_id)])
    %{fleet_id: message.fleet_id, token_ids: Enum.reject(token_ids, &is_nil/1)}
  end

  policies do
    # Spec section 7: the people and agents holding the fleet's keys, or a
    # shard of one, read every room and thread of it. Anyone else reads only
    # General and the keys' threads. Posting is for the keys alone.
    #
    # Every key's thread is read by anyone.
    policy action(:read_key_thread) do
      authorize_if always()
    end

    # A room only the keys read is refused to anyone else, never read as empty.
    policy action(:read_messages) do
      authorize_if Keyfleet.Rooms.Checks.RoomPoster
      authorize_if Keyfleet.Rooms.Checks.PublicRoom
    end

    # The reads across the fleet's rooms, which leave the keys' threads out,
    # show anyone else only General.
    policy action([
             :read,
             :posts_as_key,
             :recent_in_fleet,
             :fleet_lines_before,
             :room_posts_as_key,
             :room_posts_by_wallet,
             :in_room,
             :under_send_key
           ]) do
      authorize_if Keyfleet.Rooms.Checks.RoomPoster
      authorize_if Keyfleet.Rooms.Checks.InGeneral
    end

    policy action([:send_message, :send_to_key, :note_room_named]) do
      authorize_if Keyfleet.Rooms.Checks.RoomPoster
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

    # Whether the line is in a key's thread rather than one of the fleet's
    # rooms, kept on the line so the fleet's room lines are read without
    # looking at their rooms.
    attribute :in_key_thread, :boolean,
      allow_nil?: false,
      public?: false,
      writable?: false

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

    # The key the line was written as: the author's highest-ranked key in the
    # fleet when it was written. Lines written before keys were recorded have
    # none.
    attribute :as_key, :integer,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

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
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :room, Keyfleet.Rooms.Room do
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :agent_profile, Keyfleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
      read_action :public_profile
    end

    # The agent that wrote a person's line for them, as the agent paired with
    # them (`Keyfleet.Keys.identity/2`); nil when the person wrote it.
    belongs_to :via_agent_profile, Keyfleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
      read_action :public_profile
    end

    belongs_to :reply_to, Keyfleet.Rooms.Message do
      attribute_writable? false
      public? true
    end
  end

  calculations do
    # The first 160 characters of the line's words, cut in the database.
    calculate :excerpt, :string, expr(fragment("left(?, 160)", body)), public?: true

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
