defmodule Keyfleet.Dms.Conversation do
  @moduledoc """
  The one conversation between two Keys of a fleet, opened by the first message
  either sends the other. Its two Keys are kept lowest first (`key_a`,
  `key_b`), so a pair has exactly one.

  Either Key's holder may delete it, which removes it and every message in it
  for both, or have its messages removed after 1, 7, 30 or 90 days
  (`auto_delete_days`, nil to keep them).

  A Key reads a conversation only while it holds a message of it that its
  holder may see (`Keyfleet.Dms.Message`'s `shown_to`), and its last message
  is the last of those: a Key's new holder finds none of the old holder's
  conversations until a new message arrives in one.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Dms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  require Ash.Query

  @bigint 9_223_372_036_854_775_807
  @auto_delete_days [1, 7, 30, 90]
  # An inbox lists its most recent conversations, as many as a page shows.
  @inbox_page 100

  postgres do
    table "dm_conversations"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:key_a, "dm_conversations_key_order", check: "key_a > 0 AND key_a < key_b")

      check_constraint(:auto_delete_days, "dm_conversations_auto_delete_days",
        check: "auto_delete_days IS NULL OR auto_delete_days IN (1, 7, 30, 90)"
      )
    end

    custom_indexes do
      # The conversations of the Key on the higher side; the pair's identity
      # already reads the lower side's.
      index([:fleet_id, :key_b])
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    # One Key's conversations, the newest message it may see first: its main
    # inbox, or with `blocked` those with the Keys it has blocked.
    read :inbox do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :blocked, :boolean, allow_nil?: false, default: false

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 (key_a == ^arg(:token_id) or key_b == ^arg(:token_id)) and
                 blocked_by(token_id: ^arg(:token_id)) == ^arg(:blocked) and
                 not is_nil(last_seq(token_id: ^arg(:token_id)))
             )

      prepare {Keyfleet.Dms.Preparations.LastShown, newest_first: true}
      prepare build(limit: @inbox_page)
    end

    # The conversation between two Keys, if they have one.
    read :between do
      get? true
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :other_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 ((key_a == ^arg(:token_id) and key_b == ^arg(:other_token_id)) or
                    (key_a == ^arg(:other_token_id) and key_b == ^arg(:token_id))) and
                 not is_nil(last_seq(token_id: ^arg(:token_id)))
             )

      prepare Keyfleet.Dms.Preparations.LastShown
    end

    # Opened by the first message between two Keys, inside its sending
    # (`Keyfleet.Dms.Changes.SendMessage`); a later message meets the same row.
    create :open do
      public? false
      accept [:fleet_id, :key_a, :key_b]

      upsert? true
      upsert_identity :unique_pair
      upsert_fields [:updated_at]
    end

    update :set_auto_delete do
      change Keyfleet.Agents.Changes.RecordAuthority
      require_atomic? false
      change {RegentAgents.RequirePairing, repo: Keyfleet.Repo}
      accept [:auto_delete_days]
      validate one_of(:auto_delete_days, @auto_delete_days), where: present(:auto_delete_days)
    end

    # Everything in the conversation goes with it (`dm_messages`' foreign key).
    destroy :delete do
      require_atomic? false
      change {RegentAgents.RequirePairing, repo: Keyfleet.Repo}
      primary? true
    end
  end

  # Delivered after the deletion commits, as `%Phoenix.Socket.Broadcast{}` on
  # `Keyfleet.Dms.inbox_topic/2` of both Keys: "dm_deleted" with
  # `%{conversation_id}`.
  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "dms"
    broadcast_type :phoenix_broadcast

    publish :delete, [:fleet_id, :key_a],
      event: "dm_deleted",
      transform: &%{conversation_id: &1.data.id}

    publish :delete, [:fleet_id, :key_b],
      event: "dm_deleted",
      transform: &%{conversation_id: &1.data.id}
  end

  policies do
    policy action([:read, :open]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action([:inbox, :between]) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:token_id]}
    end

    policy action([:set_auto_delete, :delete]) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:key_a, :key_b], match: :any}
    end
  end

  attributes do
    attribute :acting_agent_wallet, :string, writable?: false
    attribute :beneficiary_privy_user_id, :string, writable?: false, sensitive?: true
    attribute :agent_pairing_id, :uuid, writable?: false

    uuid_primary_key :id

    attribute :key_a, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :key_b, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :auto_delete_days, :integer,
      public?: true,
      constraints: [min: 1, max: 90]

    timestamps(public?: true)
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end

    has_many :messages, Keyfleet.Dms.Message
  end

  calculations do
    # The last message Key `token_id`, one side of the conversation, may see.
    # Read beside the conversation, which that Key was already allowed to
    # read; the messages are filtered to the ones its holder may see, so their
    # own read policy (system only) is not asked again.
    calculate :last_seq,
              :integer,
              expr(
                max(messages,
                  field: :seq,
                  query: [filter: shown_to(token_id: ^arg(:token_id))],
                  authorize?: false
                )
              ) do
      public? true
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
    end

    calculate :last_body,
              :string,
              expr(
                first(messages,
                  field: :body,
                  query: [filter: shown_to(token_id: ^arg(:token_id)), sort: [seq: :desc]],
                  authorize?: false
                )
              ) do
      public? true
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
    end

    calculate :last_from_token_id,
              :integer,
              expr(
                first(messages,
                  field: :from_token_id,
                  query: [filter: shown_to(token_id: ^arg(:token_id)), sort: [seq: :desc]],
                  authorize?: false
                )
              ) do
      public? true
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
    end

    calculate :last_at,
              :utc_datetime_usec,
              expr(
                first(messages,
                  field: :inserted_at,
                  query: [filter: shown_to(token_id: ^arg(:token_id)), sort: [seq: :desc]],
                  authorize?: false
                )
              ) do
      public? true
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
    end

    # Whether Key `token_id`, one side of the conversation, has blocked the
    # other side.
    calculate :blocked_by,
              :boolean,
              expr(
                fragment(
                  "EXISTS (SELECT 1 FROM keyfleet_app.dm_blocks AS b WHERE b.fleet_id = ? AND b.blocker_token_id = ? AND b.blocked_token_id = (CASE WHEN ? = ? THEN ? ELSE ? END))",
                  fleet_id,
                  ^arg(:token_id),
                  key_a,
                  ^arg(:token_id),
                  key_b,
                  key_a
                )
              ) do
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
    end
  end

  identities do
    identity :unique_pair, [:fleet_id, :key_a, :key_b]
  end

  @doc "The days a conversation may keep its messages for, besides keeping them."
  def auto_delete_days, do: @auto_delete_days
end
