defmodule Keyfleet.Polls.Session do
  @moduledoc """
  One poll session in a fleet: its name, its mode, the delegate's Key, its
  seats, its rounds and its log.

  Whoever opens a session, a person or an agent, is its delegate, and their
  Key takes the first seat. A session lasts the minutes it was opened for (5
  to 60), or until the delegate ends it; after that it takes no more seats or
  rounds, and a round still open closes at its own deadline. A session is
  never removed. Anyone may read a fleet's sessions.

  Opening and ending one is announced on `Keyfleet.Polls.fleet_topic/1` as
  "polls_changed", a nudge for pages listing the fleet's sessions.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Polls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @bigint 9_223_372_036_854_775_807
  @plain_text ~r/\A[^\p{Cc}\p{Cf}\p{Zl}\p{Zp}]*\z/u

  postgres do
    table "poll_sessions"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:mode, "poll_sessions_mode", check: "mode IN ('poll', 'delegate')")
      check_constraint(:head_seq, "poll_sessions_head_seq", check: "head_seq >= 0")
      check_constraint(:delegate_key, "poll_sessions_delegate_key", check: "delegate_key > 0")

      check_constraint(:opened_by_wallet, "poll_sessions_opened_by_wallet_shape",
        check: "opened_by_wallet ~ '^0x[0-9a-f]{40}$'"
      )
    end

    custom_indexes do
      index(["fleet_id", "inserted_at"],
        name: "poll_sessions_open_index",
        where: "ended_at IS NULL"
      )
    end
  end

  actions do
    create :open do
      accept [:name, :mode]
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :minutes, :integer, allow_nil?: false, constraints: [min: 5, max: 60]

      validate Keyfleet.Graph.Validations.KnownFleet
      change set_attribute(:fleet_id, arg(:fleet_id))
      change Keyfleet.Polls.Changes.OpenSession
    end

    # The fleet's sessions still taking seats and rounds, oldest first.
    read :open_in_fleet do
      argument :fleet_id, :string, allow_nil?: false

      validate Keyfleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id) and is_nil(ended_at) and expires_at > now())
      prepare build(sort: [inserted_at: :asc, id: :asc], load: [:seat_keys])
    end

    # Every session the fleet has held, newest first: the latest hundred.
    read :listed do
      argument :fleet_id, :string, allow_nil?: false

      validate Keyfleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id))

      prepare build(
                sort: [inserted_at: :desc, id: :desc],
                limit: 100,
                load: [:seat_keys, :rounds_held]
              )
    end

    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :uuid, allow_nil?: false
      get? true

      filter expr(fleet_id == ^arg(:fleet_id) and id == ^arg(:id))
      prepare build(load: [:seat_keys, :rounds_held])
    end

    update :end do
      accept []
      require_atomic? false
      transaction? true

      argument :fleet_id, :string, allow_nil?: false

      change Keyfleet.Polls.Changes.EndSession
    end
  end

  policies do
    policy action([:open, :open_in_fleet]) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :member}
    end

    policy action([:listed, :in_fleet]) do
      authorize_if always()
    end

    policy action(:end) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :delegate}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 80, match: @plain_text]

    # `:poll`: every seated Key's vote counts. `:delegate`: only the
    # delegate's Key decides, and the other Keys' votes are suggestions.
    attribute :mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:poll, :delegate]]

    # The Key of the agent that opened the session, which opens its rounds.
    attribute :delegate_key, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

    attribute :opened_by_wallet, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    # How many lines the session's log holds (`Keyfleet.Polls.Log`).
    attribute :head_seq, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0, max: @bigint]

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true, writable?: false
    attribute :ended_at, :utc_datetime_usec, public?: true, writable?: false

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? true
      allow_nil? false
      public? true
    end

    has_many :seats, Keyfleet.Polls.Seat
    has_many :rounds, Keyfleet.Polls.Round
  end

  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "polls"
    broadcast_type :phoenix_broadcast

    publish :open, [:fleet_id], event: "polls_changed", transform: fn _notification -> %{} end
    publish :end, [:fleet_id], event: "polls_changed", transform: fn _notification -> %{} end
  end

  aggregates do
    # The Keys seated in the session, lowest first. Whoever may read the
    # session sees who sits in it.
    list :seat_keys, :seats, :token_id do
      sort token_id: :asc
      authorize? false
      public? true
    end

    count :rounds_held, :rounds do
      authorize? false
      public? true
    end
  end
end
