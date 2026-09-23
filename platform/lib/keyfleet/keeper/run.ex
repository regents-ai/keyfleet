defmodule KeyFleet.Keeper.Run do
  @moduledoc """
  One round of a keeper job that sent something, or where a pause began or
  ended. Rounds that change nothing leave no record. A run is written once,
  when it ends, and never changed or deleted. Only the keeper reads or writes
  here.
  """
  use Ash.Resource,
    domain: KeyFleet.Keeper,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807
  @jobs [:reveal, :income]
  @outcomes [
    :sent,
    :paused_gas,
    :paused_vrf_balance,
    :paused_spend_ceiling,
    :stopped,
    :error
  ]

  postgres do
    table "keeper_runs"
    repo(KeyFleet.Repo)

    check_constraints do
      check_constraint(:job, "keeper_runs_job",
        check: "job IN (#{Enum.map_join(@jobs, ", ", &"'#{&1}'")})"
      )

      check_constraint(:outcome, "keeper_runs_outcome",
        check: "outcome IN (#{Enum.map_join(@outcomes, ", ", &"'#{&1}'")})"
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

    create :record do
      accept [:job, :started_at, :finished_at, :outcome, :sent, :skipped, :notes]
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
    attribute :started_at, :utc_datetime_usec, allow_nil?: false
    attribute :finished_at, :utc_datetime_usec, allow_nil?: false
    attribute :outcome, :atom, allow_nil?: false, constraints: [one_of: @outcomes]

    # How many transactions the round sent, and how many it passed over.
    for field <- [:sent, :skipped] do
      attribute field, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
    end

    attribute :notes, :string, constraints: [max_length: 2000, trim?: false]
  end
end
