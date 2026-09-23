defmodule KeyFleet.Keeper.Transaction do
  @moduledoc """
  One transaction the keeper signed, recorded before it is sent, with its
  outcome once the chain has one.

  What was sent never changes. The outcome is written once, all together,
  and then never changes either; nothing is ever deleted. Only the keeper
  reads or writes here.
  """
  use Ash.Resource,
    domain: KeyFleet.Keeper,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @jobs [:reveal, :income]
  @functions KeyFleet.Keeper.Calls.functions()
  @statuses [:mined, :reverted, :replaced, :replaced_externally]

  postgres do
    table "keeper_txs"
    repo(KeyFleet.Repo)
    migration_defaults(sent_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:job, "keeper_txs_job",
        check: "job IN (#{Enum.map_join(@jobs, ", ", &"'#{&1}'")})"
      )

      check_constraint(:function, "keeper_txs_function",
        check: "function IN (#{Enum.map_join(@functions, ", ", &"'#{&1}'")})"
      )

      check_constraint(:status, "keeper_txs_status",
        check: "status IN (#{Enum.map_join(@statuses, ", ", &"'#{&1}'")})"
      )

      check_constraint(:target, "keeper_txs_target_shape", check: "target ~ '^0x[0-9a-f]{40}$'")

      for field <- [:tx_hash, :replaces_tx_hash] do
        check_constraint(field, "keeper_txs_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{64}$'"
        )
      end

      check_constraint(:chain_id, "keeper_txs_positive_chain_id", check: "chain_id > 0")

      for field <- [
            :nonce,
            :max_fee,
            :max_priority_fee,
            :gas_limit,
            :block_number,
            :gas_used,
            :effective_gas_price,
            :l1_fee_wei,
            :cost_wei
          ] do
        check_constraint(field, "keeper_txs_nonnegative_#{field}", check: "#{field} >= 0")
      end

      # The outcome arrives whole: a status and when it was settled, and for a
      # transaction the chain included, what it cost. Base adds an L1 fee;
      # a chain without one leaves it empty. A result comes only with a status.
      check_constraint(:status, "keeper_txs_outcome_fields",
        check: """
        num_nonnulls(status, settled_at) IN (0, 2) AND
        CASE WHEN status IN ('mined', 'reverted')
          THEN num_nonnulls(block_number, gas_used, effective_gas_price, cost_wei) = 4
          ELSE num_nonnulls(block_number, gas_used, effective_gas_price, l1_fee_wei, cost_wei) = 0
        END AND
        (status IS NOT NULL OR result IS NULL)
        """
      )
    end

    custom_indexes do
      # The transactions still waiting for an outcome.
      index([:chain_id, :nonce], where: "status IS NULL")
    end

    custom_statements do
      statement :keeper_txs_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_keeper_tx() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP <> 'UPDATE' THEN
            RAISE EXCEPTION 'keeper transactions cannot be deleted' USING ERRCODE = '23514';
          END IF;
          IF ROW(NEW.id, NEW.job, NEW.fleet_id, NEW.function, NEW.target, NEW.args, NEW.chain_id,
                 NEW.nonce, NEW.tx_hash, NEW.replaces_tx_hash, NEW.max_fee, NEW.max_priority_fee,
                 NEW.gas_limit, NEW.sent_at)
             IS DISTINCT FROM
             ROW(OLD.id, OLD.job, OLD.fleet_id, OLD.function, OLD.target, OLD.args, OLD.chain_id,
                 OLD.nonce, OLD.tx_hash, OLD.replaces_tx_hash, OLD.max_fee, OLD.max_priority_fee,
                 OLD.gas_limit, OLD.sent_at) THEN
            RAISE EXCEPTION 'what a keeper transaction sent cannot be changed' USING ERRCODE = '23514';
          END IF;
          IF OLD.status IS NOT NULL THEN
            RAISE EXCEPTION 'a settled keeper transaction cannot be changed' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_keeper_tx();")
      end

      statement :keeper_txs_trigger do
        up("""
        CREATE TRIGGER protect_keeper_txs BEFORE UPDATE OR DELETE ON keyfleet_app.keeper_txs
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_keeper_tx();
        """)

        down("DROP TRIGGER protect_keeper_txs ON keyfleet_app.keeper_txs;")
      end

      # A row trigger never sees TRUNCATE.
      statement :untruncatable_keeper_txs_trigger do
        up("""
        CREATE TRIGGER untruncatable_keeper_txs BEFORE TRUNCATE ON keyfleet_app.keeper_txs
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.protect_keeper_tx();
        """)

        down("DROP TRIGGER untruncatable_keeper_txs ON keyfleet_app.keeper_txs;")
      end
    end
  end

  actions do
    defaults [:read]

    create :record_sent do
      accept [
        :job,
        :fleet_id,
        :function,
        :target,
        :args,
        :chain_id,
        :nonce,
        :tx_hash,
        :replaces_tx_hash,
        :max_fee,
        :max_priority_fee,
        :gas_limit
      ]
    end

    # Run only through `KeyFleet.Keeper.settle/2`, whose query finds the row
    # only while it is unsettled.
    update :settle do
      accept [
        :status,
        :block_number,
        :gas_used,
        :effective_gas_price,
        :l1_fee_wei,
        :cost_wei,
        :result
      ]

      require_attributes [:status]
      change atomic_update(:settled_at, expr(now()))
    end

    # The transaction while it has no outcome yet.
    read :unsettled do
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and is_nil(status))
    end
  end

  policies do
    policy always() do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :job, :atom, allow_nil?: false, constraints: [one_of: @jobs]
    attribute :function, :atom, allow_nil?: false, constraints: [one_of: @functions]

    attribute :target, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    # The call's one argument, as `%{"arg" => value}`.
    attribute :args, :map, allow_nil?: false

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

    # Fees are wei per gas.
    for field <- [:nonce, :max_fee, :max_priority_fee, :gas_limit] do
      attribute field, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
    end

    attribute :tx_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

    # The transaction this one replaces at the same nonce with higher fees.
    attribute :replaces_tx_hash, :string,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

    attribute :sent_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false

    attribute :status, :atom, constraints: [one_of: @statuses]

    # All in wei; `cost_wei` is gas used times its price plus Base's L1 fee.
    for field <- [:block_number, :gas_used, :effective_gas_price, :l1_fee_wei, :cost_wei] do
      attribute field, :integer, constraints: [min: 0, max: @bigint]
    end

    # What the receipt showed beyond its status, such as a reveal the VRF
    # coordinator refused.
    attribute :result, :string, constraints: [max_length: 200, trim?: false]

    attribute :settled_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
    end
  end

  identities do
    identity :unique_tx_hash, [:tx_hash]
  end
end
