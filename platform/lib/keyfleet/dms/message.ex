defmodule Keyfleet.Dms.Message do
  @moduledoc """
  One direct message from one Key of a fleet to another, in their
  conversation. Its words come with up to eight parts (`Keyfleet.Dms.Part`):
  more text, a small JSON object, or a link, which is how a file is sent.

  `seq` is the message's place among every direct message, given by the
  database and only ever growing, so a reader carries on after the last one it
  saw. The fleet's messages are written one at a time
  (`Keyfleet.Dms.Changes.SendMessage`), so within a fleet that order is the
  order they become readable.

  Messages are never edited. They are removed with their conversation, or by
  the hourly job when their conversation's auto-delete days have passed
  (`:remove_expired`).
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Dms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban]

  require Ash.Query

  alias Keyfleet.Actors.System

  @bigint 9_223_372_036_854_775_807
  @max_body 4_000
  @max_parts 8
  @max_page 200
  @max_keys 100

  postgres do
    table "dm_messages"
    repo(Keyfleet.Repo)
    migration_types(seq: :bigserial)
    migration_defaults(inserted_at: "fragment(\"(clock_timestamp() AT TIME ZONE 'utc')\")")

    references do
      reference(:conversation, on_delete: :delete)
    end

    check_constraints do
      check_constraint(:to_token_id, "dm_messages_two_keys",
        check: "from_token_id > 0 AND to_token_id > 0 AND from_token_id <> to_token_id"
      )

      check_constraint(:body, "dm_messages_body_length",
        check: "length(body) BETWEEN 1 AND #{@max_body}"
      )

      check_constraint(:author_wallet, "dm_messages_author_wallet_shape",
        check: "author_wallet ~ '^0x[0-9a-f]{40}$'"
      )
    end

    custom_indexes do
      # One conversation in order, and its messages by age for auto-delete.
      index([:conversation_id, :seq])
      index([:conversation_id, :inserted_at])

      # What one Key sent and received, in order, for catching up.
      index([:fleet_id, :from_token_id, :seq])
      index([:fleet_id, :to_token_id, :seq])
    end
  end

  oban do
    scheduled_actions do
      # Every hour, the messages past their conversation's auto-delete days.
      schedule :remove_expired, "0 * * * *" do
        action :remove_expired
        queue(:default)
        worker_module_name(Keyfleet.Dms.Message.AshOban.ActionWorker.RemoveExpired)
      end
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    create :send do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :from_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :to_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      argument :body, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: @max_body, trim?: true]

      argument :parts, {:array, Keyfleet.Dms.Part},
        allow_nil?: false,
        default: [],
        constraints: [max_length: @max_parts, nil_items?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128, trim?: false]

      # The sending Key's own send key settles a repeat: the database hands back
      # the message it already sent rather than writing a second.
      upsert? true
      upsert_identity :unique_send_key
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      validate Keyfleet.Graph.Validations.KnownFleet
      validate {Keyfleet.Rooms.Validations.IssuedKey, argument: :to_token_id}
      validate {Keyfleet.Dms.Validations.TwoKeys, from: :from_token_id, to: :to_token_id}
      change Keyfleet.Dms.Changes.LimitSends
      change Keyfleet.Dms.Changes.SendMessage
    end

    # The conversation between two Keys, oldest first, after a place in it.
    read :in_conversation do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :other_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :after_seq, :integer, default: 0, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: @max_page]

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 ((from_token_id == ^arg(:token_id) and to_token_id == ^arg(:other_token_id)) or
                    (from_token_id == ^arg(:other_token_id) and to_token_id == ^arg(:token_id)))
             )

      filter expr(seq > ^arg(:after_seq))

      prepare build(load: [:via_agent])
      prepare Keyfleet.Dms.Preparations.InOrder
    end

    # The newest messages between two Keys, newest first, for the page.
    read :latest do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :other_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :limit, :integer, default: 100, constraints: [min: 1, max: @max_page]

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 ((from_token_id == ^arg(:token_id) and to_token_id == ^arg(:other_token_id)) or
                    (from_token_id == ^arg(:other_token_id) and to_token_id == ^arg(:token_id)))
             )

      prepare build(load: [:via_agent])
      prepare {Keyfleet.Preparations.NewestFirst, sort: [seq: :desc], before: []}
    end

    # The messages to or from any of the Keys after a place, oldest first,
    # without those sent to one of them by a Key it has blocked.
    read :changes do
      argument :fleet_id, :string, allow_nil?: false

      argument :token_ids, {:array, :integer},
        allow_nil?: false,
        constraints: [
          min_length: 1,
          max_length: @max_keys,
          items: [min: 1, max: @bigint]
        ]

      argument :after_seq, :integer, default: 0, constraints: [min: 0, max: @bigint]
      argument :limit, :integer, default: 50, constraints: [min: 1, max: @max_page]

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and seq > ^arg(:after_seq) and
                 (from_token_id in ^arg(:token_ids) or
                    (to_token_id in ^arg(:token_ids) and not sender_blocked))
             )

      prepare Keyfleet.Dms.Preparations.InOrder
    end

    # The messages whose conversation's auto-delete days have passed.
    read :expired do
      public? false

      filter expr(
               not is_nil(conversation.auto_delete_days) and
                 fragment(
                   "? < (now() AT TIME ZONE 'utc') - ? * interval '1 day'",
                   inserted_at,
                   conversation.auto_delete_days
                 )
             )
    end

    destroy :expire do
      public? false
    end

    # Run every hour by the scheduled job above.
    action :remove_expired do
      run fn _input, _context ->
        __MODULE__
        |> Ash.Query.for_read(:expired, %{}, actor: %System{})
        |> Ash.bulk_destroy!(:expire, %{},
          actor: %System{},
          strategy: [:atomic, :stream],
          return_errors?: true
        )

        :ok
      end
    end
  end

  # Delivered after the message commits, as `%Phoenix.Socket.Broadcast{}` on
  # `Keyfleet.Dms.inbox_topic/2` of the Key that sent it and the Key it went
  # to: "dm_head" with `%{conversation_id, seq, from_token_id}`. A repeat the
  # database handed back is not announced.
  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "dms"
    broadcast_type :phoenix_broadcast
    filter &(!Ash.Resource.get_metadata(&1.data, :upsert_skipped))

    publish :send, [:fleet_id, :from_token_id], event: "dm_head", transform: &__MODULE__.head/1
    publish :send, [:fleet_id, :to_token_id], event: "dm_head", transform: &__MODULE__.head/1
  end

  @doc false
  def head(%{data: message}),
    do: %{
      conversation_id: message.conversation_id,
      seq: message.seq,
      from_token_id: message.from_token_id
    }

  policies do
    policy action(:send) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:from_token_id]}
    end

    policy action([:in_conversation, :latest]) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:token_id]}
    end

    policy action(:changes) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:token_ids]}
    end

    policy action([:read, :expired, :expire]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:remove_expired) do
      authorize_if AshOban.Checks.AshObanInteraction
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :seq, :integer,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :from_token_id, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :to_token_id, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :body, :string,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min_length: 1, max_length: @max_body, trim?: false]

    attribute :parts, {:array, Keyfleet.Dms.Part},
      allow_nil?: false,
      default: [],
      writable?: false,
      public?: true

    # The wallet the message came from: the person's wallet holding the Key,
    # or the agent's own.
    attribute :author_wallet, :string,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    attribute :idempotency_key, :string,
      allow_nil?: false,
      writable?: false,
      public?: false,
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

    belongs_to :conversation, Keyfleet.Dms.Conversation do
      attribute_writable? false
      allow_nil? false
      public? true
    end

    # The agent that wrote it, for its Key or for the person it is paired
    # with; nil when a person wrote it.
    belongs_to :via_agent, Keyfleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
      read_action :public_profile
    end
  end

  calculations do
    # Whether the Key the message went to has blocked the Key that sent it.
    calculate :sender_blocked,
              :boolean,
              expr(
                fragment(
                  "EXISTS (SELECT 1 FROM keyfleet_app.dm_blocks AS b WHERE b.fleet_id = ? AND b.blocker_token_id = ? AND b.blocked_token_id = ?)",
                  fleet_id,
                  to_token_id,
                  from_token_id
                )
              )
  end

  identities do
    identity :unique_send_key, [:fleet_id, :from_token_id, :idempotency_key]
  end
end
