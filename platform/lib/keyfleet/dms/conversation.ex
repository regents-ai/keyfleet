defmodule Keyfleet.Dms.Conversation do
  @moduledoc """
  The one conversation between two Keys of a fleet, opened by the first message
  either sends the other. Its two Keys are kept lowest first (`key_a`,
  `key_b`), so a pair has exactly one.

  Either Key's holder may delete it, which removes it and every message in it
  for both, or have its messages removed after 1, 7, 30 or 90 days
  (`auto_delete_days`, nil to keep them).
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

    # One Key's conversations, the newest message first: its main inbox, or
    # with `blocked` those with the Keys it has blocked.
    read :inbox do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :blocked, :boolean, allow_nil?: false, default: false

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 (key_a == ^arg(:token_id) or key_b == ^arg(:token_id)) and
                 blocked_by(token_id: ^arg(:token_id)) == ^arg(:blocked)
             )

      prepare build(
                load: [:last_seq, :last_body, :last_from_token_id, :last_at],
                sort: [last_seq: :desc_nils_last, id: :asc],
                limit: @inbox_page
              )
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
                    (key_a == ^arg(:other_token_id) and key_b == ^arg(:token_id)))
             )
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
      accept [:auto_delete_days]
      validate one_of(:auto_delete_days, @auto_delete_days), where: present(:auto_delete_days)
    end

    # Everything in the conversation goes with it (`dm_messages`' foreign key).
    destroy :delete do
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

  # Read beside the conversation it belongs to, which the reader was already
  # allowed to see; its messages are that conversation's own.
  aggregates do
    max :last_seq, :messages, :seq, authorize?: false, public?: true

    first :last_body, :messages, :body do
      sort seq: :desc
      authorize? false
      public? true
    end

    first :last_from_token_id, :messages, :from_token_id do
      sort seq: :desc
      authorize? false
      public? true
    end

    first :last_at, :messages, :inserted_at do
      sort seq: :desc
      authorize? false
      public? true
    end
  end

  calculations do
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
