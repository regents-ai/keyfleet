defmodule Keyfleet.Dms.Block do
  @moduledoc """
  One Key of a fleet blocking another. The block is the Key's, kept by its
  number, so it stays with the Key when the Key is sold and its new holder
  can lift it.

  A blocked Key can still send: its messages are saved, and its conversation
  shows in the blocker's Blocked inbox instead of the main one
  (`Keyfleet.Dms.Conversation`'s `:inbox`).
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Dms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807

  postgres do
    table "dm_blocks"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:blocked_token_id, "dm_blocks_two_keys",
        check:
          "blocker_token_id > 0 AND blocked_token_id > 0 AND blocker_token_id <> blocked_token_id"
      )
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    # Blocking a Key that is already blocked keeps the block it has.
    create :block do
      accept []

      argument :fleet_id, :string, allow_nil?: false
      argument :blocker_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :blocked_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      upsert? true
      upsert_identity :unique_block
      upsert_fields [:updated_at]

      validate Keyfleet.Graph.Validations.KnownFleet
      validate {Keyfleet.Rooms.Validations.IssuedKey, argument: :blocked_token_id}
      validate {Keyfleet.Dms.Validations.TwoKeys, from: :blocker_token_id, to: :blocked_token_id}

      change set_attribute(:fleet_id, arg(:fleet_id))
      change set_attribute(:blocker_token_id, arg(:blocker_token_id))
      change set_attribute(:blocked_token_id, arg(:blocked_token_id))
    end

    destroy :unblock

    # The Keys one Key has blocked, lowest first.
    read :of_key do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      validate Keyfleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id) and blocker_token_id == ^arg(:token_id))
      prepare build(sort: [blocked_token_id: :asc])
    end

    # One Key's block of another, if it has one.
    read :pair do
      get? true
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :other_token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and blocker_token_id == ^arg(:token_id) and
                 blocked_token_id == ^arg(:other_token_id)
             )
    end
  end

  policies do
    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action([:block, :unblock]) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:blocker_token_id]}
    end

    policy action([:of_key, :pair]) do
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:token_id]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :blocker_token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :blocked_token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    timestamps(public?: true)
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_block, [:fleet_id, :blocker_token_id, :blocked_token_id]
  end
end
