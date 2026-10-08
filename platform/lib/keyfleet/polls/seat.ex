defmodule Keyfleet.Polls.Seat do
  @moduledoc """
  A Key's seat in a poll session. A Key has at most one, whichever of its
  agents took it; any agent of a seated Key reads the session and votes for
  it. A Key seated when a round opens has a vote in that round.

  Joining a session the Key already sits in changes nothing. The delegate's
  Key keeps its seat for as long as the session lasts; any other Key may give
  its seat up.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Polls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807

  postgres do
    table "poll_seats"
    repo(Keyfleet.Repo)

    references do
      reference(:session, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:token_id, "poll_seats_token_id", check: "token_id > 0")

      check_constraint(:joined_by_wallet, "poll_seats_joined_by_wallet_shape",
        check: "joined_by_wallet ~ '^0x[0-9a-f]{40}$'"
      )
    end
  end

  actions do
    create :join do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :session_id, :uuid, allow_nil?: false

      # The database hands back the seat the Key already has.
      upsert? true
      upsert_identity :unique_key
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      change {Keyfleet.Polls.Changes.TakeSeat, as: :actor}
    end

    # The delegate's seat, taken as its session opens.
    create :seat_delegate do
      public? false
      accept []

      argument :session_id, :uuid, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :wallet, :string, allow_nil?: false

      change {Keyfleet.Polls.Changes.TakeSeat, as: :delegate}
    end

    destroy :leave do
      require_atomic? false
      transaction? true

      argument :fleet_id, :string, allow_nil?: false

      change Keyfleet.Polls.Changes.LeaveSeat
    end

    read :read do
      primary? true
      public? false
    end

    read :of_key do
      public? false
      argument :session_id, :uuid, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      get? true

      filter expr(session_id == ^arg(:session_id) and token_id == ^arg(:token_id))
    end

    read :in_session do
      public? false
      argument :session_id, :uuid, allow_nil?: false

      filter expr(session_id == ^arg(:session_id))
      prepare build(sort: [token_id: :asc])
    end
  end

  policies do
    policy action(:join) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :member}
    end

    policy action(:leave) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :own_seat}
    end

    policy action([:seat_delegate, :read, :of_key, :in_session]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

    attribute :joined_by_wallet, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :session, Keyfleet.Polls.Session do
      attribute_writable? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_key, [:session_id, :token_id]
  end
end
