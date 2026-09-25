defmodule Keyfleet.Keys.KeyPairing do
  @moduledoc """
  One operator's attachment to one key, for one ownership epoch.

  A pairing never changes the key it names, the epoch it belongs to or the
  operator it attaches. Only its lifecycle columns and the owner's limits move,
  so the table is the complete history of who operated a key and under which
  owner.

  The limits are four plain sentences the owner writes when approving, and may
  change while the agent runs the key: what it may commit about money, about
  the owner's information, outside Keyfleet, and what it must check with the
  owner first. Keyfleet shows them to everyone and enforces nothing more
  because of them. An agent signing from the owner's own wallet holds its own
  key, and its pairing has none.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @limit [min_length: 1, max_length: 500, trim?: true]
  @limit_arguments [:money, :information, :outside, :check_first]

  postgres do
    table "key_pairings"
    repo(Keyfleet.Repo)
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

      # The four limits and when they were written are all there or all absent.
      check_constraint(:limits_money, "key_pairings_limits_whole",
        check:
          "num_nulls(limits_money, limits_information, limits_outside, limits_check_first, limits_written_at) IN (0, 5)"
      )
    end

    custom_indexes do
      # Whether an agent runs one of a fleet's keys right now, asked of every
      # agent when the fleet directory lists who's here.
      index([:agent_profile_id, :fleet_id],
        name: "key_pairings_agent_running_index",
        where: "status = 'active'"
      )

      # Every pairing an agent has had, when its keys are counted.
      index([:agent_profile_id], name: "key_pairings_agent_index")
    end

    custom_indexes do
      # The fleet's agents starting and stopping work on its keys, newest
      # first, for its activity.
      index(["fleet_id", "approved_at DESC"],
        name: "key_pairings_approved_index",
        where: "approved_at IS NOT NULL"
      )

      index(["fleet_id", "ended_at DESC"],
        name: "key_pairings_ended_index",
        where: "ended_at IS NOT NULL AND approved_at IS NOT NULL"
      )
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
    # An agent's pairings, when agents are read with the keys they run.
    read :read do
      primary? true
      public? false
    end

    create :request_pairing do
      accept []
      transaction? true

      argument :fleet_id, :string, allow_nil?: false

      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      validate Keyfleet.Graph.Validations.KnownFleet
      change Keyfleet.Keys.Changes.OpenPairing
      change Keyfleet.Keys.Changes.AnnounceOperator
    end

    update :approve_pairing do
      accept []
      require_atomic? false
      transaction? true

      for limit <- @limit_arguments do
        argument limit, :string, allow_nil?: false, constraints: @limit
      end

      change {Keyfleet.Keys.Changes.DecideOnce, from: :requested}
      change Keyfleet.Keys.Changes.TakeOverKey
      change set_attribute(:status, :active)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
      change Keyfleet.Keys.Changes.WriteLimits
      change Keyfleet.Keys.Changes.AnnounceOperator
    end

    # The owner rewrites the limits of the agent running their key.
    update :set_limits do
      accept []
      require_atomic? false

      for limit <- @limit_arguments do
        argument limit, :string, allow_nil?: false, constraints: @limit
      end

      change {Keyfleet.Keys.Changes.DecideOnce, from: :active}
      change Keyfleet.Keys.Changes.WriteLimits
    end

    update :decline_pairing do
      accept []
      require_atomic? false
      change {Keyfleet.Keys.Changes.DecideOnce, from: :requested}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :declined)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :withdraw_pairing_request do
      accept []
      require_atomic? false
      change {Keyfleet.Keys.Changes.DecideOnce, from: :requested}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :declined)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :detach_operator do
      accept []
      require_atomic? false
      change {Keyfleet.Keys.Changes.DecideOnce, from: :active}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :detached)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change Keyfleet.Keys.Changes.AnnounceOperator
    end

    # The running agent stops running the key. Giving up the key is always
    # allowed, whoever holds it now and however fresh ownership is.
    update :step_down do
      accept []
      require_atomic? false
      change {Keyfleet.Keys.Changes.DecideOnce, from: :active}
      change set_attribute(:status, :ended)
      change set_attribute(:ended_reason, :stepped_down)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change Keyfleet.Keys.Changes.AnnounceOperator
    end

    # Reached only through `Keyfleet.Keys.PairingLedger`, on behalf of an owner
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

    # Every key of the fleet an agent runs today, by number, for the key map.
    read :run_in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and effective?)
      prepare build(select: [:token_id], sort: [token_id: :asc])
    end

    # The fleet's pairings approved before the one approved at `before_at`
    # with `before_id` (from the newest when nil), newest first, `limit` at
    # most: each an agent starting work on a key.
    read :arrivals_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_at, :utc_datetime_usec
      argument :before_id, :uuid
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 100]

      filter expr(fleet_id == ^arg(:fleet_id) and not is_nil(approved_at))

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [approved_at: :desc, id: :asc], before: [:before_at, :before_id]}

      prepare build(load: [:agent_profile])
    end

    # The fleet's approved pairings that ended before the one that ended at
    # `before_at` with `before_id`, the same way: each an agent that stopped
    # work on a key, for whatever reason.
    read :departures_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_at, :utc_datetime_usec
      argument :before_id, :uuid
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 100]

      filter expr(
               fleet_id == ^arg(:fleet_id) and not is_nil(ended_at) and not is_nil(approved_at)
             )

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [ended_at: :desc, id: :asc], before: [:before_at, :before_id]}

      prepare build(load: [:agent_profile])
    end

    # For each of these agents, the latest key it was approved for after
    # `after` in a fleet other than `fleet_id` and still runs there.
    read :runs_elsewhere do
      argument :fleet_id, :string, allow_nil?: false

      argument :agent_profile_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [max_length: 100]

      argument :after, :utc_datetime_usec, allow_nil?: false

      filter expr(
               agent_profile_id in ^arg(:agent_profile_ids) and fleet_id != ^arg(:fleet_id) and
                 approved_at > ^arg(:after) and effective?
             )

      prepare build(
                select: [:id, :fleet_id, :token_id, :agent_profile_id, :approved_at],
                distinct: [:agent_profile_id],
                distinct_sort: [agent_profile_id: :asc, approved_at: :desc]
              )
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

    # The lowest-numbered key this operator runs in the fleet right now: the
    # key it is in that fleet, and writes everything there as.
    read :my_identity_in_fleet do
      public? false
      argument :fleet_id, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and operator_wallet == ^actor(:wallet_address) and
                 status == :active and ownership_epoch == current_ownership_epoch
             )

      prepare build(sort: [token_id: :asc], limit: 1)
      get? true
    end

    # Every key of the fleet this operator runs right now, by number, each
    # with the owner's limits on it.
    read :my_keys_in_fleet do
      public? false
      argument :fleet_id, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and operator_wallet == ^actor(:wallet_address) and
                 effective?
             )

      prepare build(sort: [token_id: :asc], limit: 100)
    end

    read :my_open_request do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and
                 status == :requested and operator_wallet == ^actor(:wallet_address)
             )

      get? true
    end

    # The key this agent runs, under whichever owner approved it.
    read :my_active_pairing do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      validate Keyfleet.Graph.Validations.KnownFleet

      filter expr(
               fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id) and
                 status == :active and operator_wallet == ^actor(:wallet_address)
             )

      get? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([
             :my_pairings,
             :my_open_request,
             :my_active_pairing,
             :my_identity_in_fleet,
             :my_keys_in_fleet
           ]) do
      authorize_if Keyfleet.Checks.AgentActor
    end

    policy action(:request_pairing) do
      authorize_if Keyfleet.Checks.AgentActor
    end

    policy action([:withdraw_pairing_request, :step_down]) do
      forbid_unless Keyfleet.Checks.AgentActor
      authorize_if expr(operator_wallet == ^actor(:wallet_address))
    end

    policy action([:approve_pairing, :set_limits, :decline_pairing, :detach_operator]) do
      authorize_if Keyfleet.Keys.Checks.KeyOwner
    end

    policy action(:end_pairing) do
      authorize_if Keyfleet.Checks.SystemActor
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
      constraints: [one_of: [:replaced, :detached, :declined, :stepped_down]]

    attribute :requested_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true

    for field <- [:approved_at, :ended_at] do
      attribute field, :utc_datetime_usec, writable?: false, public?: true
    end

    for field <- [:limits_money, :limits_information, :limits_outside, :limits_check_first] do
      attribute field, :string, public?: true, writable?: false, constraints: @limit
    end

    attribute :limits_written_at, :utc_datetime_usec, public?: true, writable?: false
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :agent_profile, Keyfleet.Agents.AgentProfile do
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
