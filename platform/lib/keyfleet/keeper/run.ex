defmodule Keyfleet.Keeper.Run do
  @moduledoc """
  One round of a keeper job that sent something, or where a pause began or
  ended: each `:paused_*` outcome has its `:unpaused_*`, and a VRF balance
  pause names its fleet. Rounds that change nothing leave no record. A run
  is written once, when it ends, and never changed or deleted. Only the
  keeper reads or writes here.

  A run `:stopped` with a `stop_reason` stops the keeper, across restarts,
  until a later run `:resumed` clears it; `bin/keeper-resume` writes that.
  """
  use Ash.Resource,
    domain: Keyfleet.Keeper,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @jobs [:reveal, :income]
  @pause_outcomes [
    :paused_gas,
    :unpaused_gas,
    :paused_vrf_balance,
    :unpaused_vrf_balance,
    :paused_spend_ceiling,
    :unpaused_spend_ceiling
  ]
  @outcomes [:sent | @pause_outcomes] ++ [:stopped, :resumed, :error]
  @stop_reasons [:foreign_nonce, :replaced_externally, :tx_hash_mismatch]

  postgres do
    table "keeper_runs"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:job, "keeper_runs_job",
        check: "job IN (#{Enum.map_join(@jobs, ", ", &"'#{&1}'")})"
      )

      check_constraint(:outcome, "keeper_runs_outcome",
        check: "outcome IN (#{Enum.map_join(@outcomes, ", ", &"'#{&1}'")})"
      )

      check_constraint(:stop_reason, "keeper_runs_stop_reason",
        check: "stop_reason IN (#{Enum.map_join(@stop_reasons, ", ", &"'#{&1}'")})"
      )

      # A stop, and only a stop, says why.
      check_constraint(:stop_reason, "keeper_runs_stop_has_reason",
        check: "(outcome = 'stopped') = (stop_reason IS NOT NULL)"
      )

      # A VRF balance pause, and only one, names its fleet.
      check_constraint(:fleet_id, "keeper_runs_vrf_balance_has_fleet",
        check:
          "(outcome IN ('paused_vrf_balance', 'unpaused_vrf_balance')) = (fleet_id IS NOT NULL)"
      )

      check_constraint(:finished_at, "keeper_runs_finished_after_start",
        check: "finished_at >= started_at"
      )

      for field <- [:sent, :skipped] do
        check_constraint(field, "keeper_runs_nonnegative_#{field}", check: "#{field} >= 0")
      end
    end

    custom_statements do
      statement :keeper_runs_function do
        up("""
        CREATE FUNCTION keyfleet_app.refuse_keeper_run_change() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'keeper runs cannot be changed or deleted' USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.refuse_keeper_run_change();")
      end

      statement :keeper_runs_trigger do
        up("""
        CREATE TRIGGER immutable_keeper_runs BEFORE UPDATE OR DELETE ON keyfleet_app.keeper_runs
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.refuse_keeper_run_change();
        """)

        down("DROP TRIGGER immutable_keeper_runs ON keyfleet_app.keeper_runs;")
      end

      # A row trigger never sees TRUNCATE.
      statement :untruncatable_keeper_runs_trigger do
        up("""
        CREATE TRIGGER untruncatable_keeper_runs BEFORE TRUNCATE ON keyfleet_app.keeper_runs
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_keeper_run_change();
        """)

        down("DROP TRIGGER untruncatable_keeper_runs ON keyfleet_app.keeper_runs;")
      end
    end
  end

  actions do
    defaults [:read]

    # A job's most recent run.
    read :last do
      argument :job, :atom, allow_nil?: false, constraints: [one_of: @jobs]
      get? true
      filter expr(job == ^arg(:job))
      prepare build(sort: [finished_at: :desc], limit: 1)
    end

    # The latest stop or resume: the keeper is stopped while it is a stop.
    read :stop_state do
      get? true
      filter expr(outcome in [:stopped, :resumed])
      prepare build(sort: [finished_at: :desc], limit: 1)
    end

    # The latest start or end of one kind of pause, given as its two
    # outcomes, for `fleet_id` when that kind names a fleet.
    read :pause_state do
      argument :outcomes, {:array, :atom},
        allow_nil?: false,
        constraints: [items: [one_of: @pause_outcomes]]

      argument :fleet_id, :string
      get? true

      filter expr(
               outcome in ^arg(:outcomes) and
                 (is_nil(^arg(:fleet_id)) or fleet_id == ^arg(:fleet_id))
             )

      prepare build(sort: [finished_at: :desc], limit: 1)
    end

    create :record do
      accept [
        :job,
        :started_at,
        :finished_at,
        :outcome,
        :stop_reason,
        :fleet_id,
        :sent,
        :skipped,
        :notes
      ]
    end
  end

  policies do
    policy always() do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :job, :atom, allow_nil?: false, constraints: [one_of: @jobs]
    attribute :started_at, :utc_datetime_usec, allow_nil?: false
    attribute :finished_at, :utc_datetime_usec, allow_nil?: false
    attribute :outcome, :atom, allow_nil?: false, constraints: [one_of: @outcomes]
    attribute :stop_reason, :atom, constraints: [one_of: @stop_reasons]

    # How many transactions the round sent, and how many it passed over.
    for field <- [:sent, :skipped] do
      attribute field, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
    end

    attribute :notes, :string, constraints: [max_length: 2000, trim?: false]
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet, attribute_type: :string
  end
end
