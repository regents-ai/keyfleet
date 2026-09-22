defmodule KeyFleet.Keys.KeyPairing do
  @moduledoc """
  One operator's attachment to one key, for one ownership epoch.

  A pairing never changes the key it names, the epoch it belongs to or the
  operator it attaches. Only its lifecycle columns move, so the table is the
  complete history of who operated a key and under which owner.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: KeyFleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807

  postgres do
    table "key_pairings"
    repo(KeyFleet.Repo)
    # Two agents can ask for the same key inside one transaction, and the order
    # they asked in is what the owner sees, so this is the statement's clock.
    migration_defaults(requested_at: "fragment(\"(clock_timestamp() AT TIME ZONE 'utc')\")")

    identity_wheres_to_sql(
      one_active_operator: "status = 'active'",
      one_open_request: "status = 'requested'"
    )

    check_constraints do
      check_constraint(:token_id, "key_pairings_positive_token", check: "token_id > 0")

      check_constraint(:ownership_epoch, "key_pairings_nonnegative_epoch",
        check: "ownership_epoch >= 0"
      )

      for field <- [:owner_wallet, :operator_wallet] do
        check_constraint(field, "key_pairings_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{40}$'"
        )
      end
    end

    custom_statements do
      statement :immutable_pairings_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_key_pairing() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'key pairings cannot be deleted' USING ERRCODE = '23514';
          END IF;
          IF ROW(NEW.id, NEW.fleet_id, NEW.token_id, NEW.ownership_epoch, NEW.owner_wallet,
                 NEW.operator_wallet, NEW.agent_profile_id, NEW.requested_at)
             IS DISTINCT FROM
             ROW(OLD.id, OLD.fleet_id, OLD.token_id, OLD.ownership_epoch, OLD.owner_wallet,
                 OLD.operator_wallet, OLD.agent_profile_id, OLD.requested_at) THEN
            RAISE EXCEPTION 'key pairing identity is immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_key_pairing();")
      end

      statement :immutable_pairings_trigger do
        up("""
        CREATE TRIGGER immutable_key_pairings BEFORE UPDATE OR DELETE ON keyfleet_app.key_pairings
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_key_pairing();
        """)

        down("""
        DROP TRIGGER immutable_key_pairings ON keyfleet_app.key_pairings;
        """)
      end

      # Emptying the table is refused too; a row trigger never sees TRUNCATE.
      statement :untruncatable_pairings_function do
        up("""
        CREATE FUNCTION keyfleet_app.refuse_key_pairing_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'key pairings cannot be deleted' USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.refuse_key_pairing_truncate();")
      end

      statement :untruncatable_pairings_trigger do
        up("""
        CREATE TRIGGER untruncatable_key_pairings BEFORE TRUNCATE ON keyfleet_app.key_pairings
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_key_pairing_truncate();
        """)

        down("""
        DROP TRIGGER untruncatable_key_pairings ON keyfleet_app.key_pairings;
        """)
      end
    end
  end

  actions do
    create :request_pairing do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false

      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      change KeyFleet.Keys.Changes.OpenPairing
    end

    update :approve_pairing do
      accept []
      require_atomic? false
      transaction? true
      change {KeyFleet.Keys.Changes.DecideOnce, from: :requested}
      change KeyFleet.Keys.Changes.TakeOverKey
      change set_attribute(:status, :active)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :decline_pairing do
      accept []
      require_atomic? false
      change {KeyFleet.Keys.Changes.DecideOnce, from: :requested}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :declined)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :withdraw_pairing_request do
      accept []
      require_atomic? false
      change {KeyFleet.Keys.Changes.DecideOnce, from: :requested}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :declined)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :detach_operator do
      accept []
      require_atomic? false
      change {KeyFleet.Keys.Changes.DecideOnce, from: :active}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :detached)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    # Reached only through `KeyFleet.Keys.PairingLedger`, on behalf of an owner
    # or operator the calling action has already admitted.
    update :end_pairing do
      public? false
      accept []

      argument :ended_reason, :atom,
        allow_nil?: false,
        constraints: [one_of: [:replaced, :declined]]

      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, arg(:ended_reason))
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    read :open_pairings_on_key do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:requested, :active]]

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and
                 status == ^arg(:status)
             )
    end

    read :current_operator do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and status == :active and
                 ownership_epoch == current_ownership_epoch
             )

      prepare build(load: [:agent_profile, :effective?])
      get? true
    end

    # The operator running each of these keys of the fleet today.
    read :operators_in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_ids, {:array, :integer}, allow_nil?: false, constraints: [max_length: 100]

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id in ^arg(:token_ids) and status == :active and
                 ownership_epoch == current_ownership_epoch
             )

      prepare build(load: [:agent_profile])
    end

    read :pairing_requests do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and
                 status == :requested and ownership_epoch == current_ownership_epoch
             )

      prepare build(load: [:agent_profile], sort: [requested_at: :asc])
    end

    read :pairing_history do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      filter expr(fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id))

      prepare build(
                load: [:agent_profile, :effective?],
                sort: [ownership_epoch: :asc, requested_at: :asc]
              )
    end

    read :my_pairings do
      filter expr(operator_wallet == ^actor(:wallet_address))

      prepare build(load: [:effective?], sort: [requested_at: :desc])
    end

    # Whether this operator is running any key in the fleet right now, which is
    # what lets it work alongside that fleet's key holders.
    read :my_effective_pairings do
      public? false
      argument :fleet_id, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and operator_wallet == ^actor(:wallet_address) and
                 status == :active and ownership_epoch == current_ownership_epoch
             )
    end

    read :my_open_request do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and
                 status == :requested and operator_wallet == ^actor(:wallet_address)
             )

      get? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:my_pairings, :my_open_request, :my_effective_pairings]) do
      authorize_if KeyFleet.Checks.AgentActor
    end

    policy action(:request_pairing) do
      authorize_if KeyFleet.Checks.AgentActor
    end

    policy action(:withdraw_pairing_request) do
      forbid_unless KeyFleet.Checks.AgentActor
      authorize_if expr(operator_wallet == ^actor(:wallet_address))
    end

    policy action([:approve_pairing, :decline_pairing, :detach_operator]) do
      authorize_if KeyFleet.Keys.Checks.KeyOwner
    end

    policy action(:end_pairing) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @bigint]

    attribute :ownership_epoch, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: @bigint]

    for field <- [:owner_wallet, :operator_wallet] do
      attribute field, :string,
        allow_nil?: false,
        public?: true,
        writable?: false,
        constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]
    end

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: :requested,
      constraints: [one_of: [:requested, :active, :ended]]

    attribute :ended_reason, :atom,
      public?: true,
      writable?: false,
      constraints: [one_of: [:replaced, :detached, :declined]]

    attribute :requested_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true

    for field <- [:approved_at, :ended_at] do
      attribute field, :utc_datetime_usec, writable?: false, public?: true
    end
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :agent_profile, KeyFleet.Agents.AgentProfile do
      attribute_writable? false
      allow_nil? false
      public? true
      read_action :public_profile
    end
  end

  calculations do
    # The epoch table has no scope-free read action to relate to, so the key's
    # latest epoch is read as one scalar subquery instead of an aggregate.
    calculate :current_ownership_epoch,
              :integer,
              expr(
                fragment(
                  "(SELECT max(epoch.ownership_epoch) FROM keyfleet_app.key_attachments AS epoch WHERE epoch.fleet_id = ? AND epoch.token_id = ?)",
                  fleet_id,
                  token_id
                )
              )

    calculate :effective?,
              :boolean,
              expr(status == :active and ownership_epoch == current_ownership_epoch)
  end

  identities do
    identity :one_active_operator, [:fleet_id, :token_id] do
      where expr(status == :active)
    end

    identity :one_open_request, [:fleet_id, :token_id, :agent_profile_id] do
      where expr(status == :requested)
    end
  end
end
