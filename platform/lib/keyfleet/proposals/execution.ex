defmodule KeyFleet.Proposals.Execution do
  @moduledoc """
  One `ProposalExecuted` log: a recorded proposal carried out, which happens
  at most once. Only the chain reader writes it, and nothing ever changes it.
  """
  use Ash.Resource,
    domain: KeyFleet.Proposals,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "proposal_executions"
    repo(KeyFleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:executor, "proposal_executions_executor_shape",
        check: "executor ~ '^0x[0-9a-f]{40}$'"
      )

      for field <- [:block_hash, :transaction_hash] do
        check_constraint(field, "proposal_executions_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{64}$'"
        )
      end

      for field <- [:block_number, :log_index] do
        check_constraint(field, "proposal_executions_nonnegative_#{field}",
          check: "#{field} >= 0"
        )
      end

      check_constraint(:record_seq, "proposal_executions_positive_record_seq",
        check: "record_seq > 0"
      )
    end

    custom_indexes do
      # What the second reading of the last blocks compares with.
      index([:fleet_id, :block_number])
    end

    custom_statements do
      statement :immutable_proposal_executions_trigger do
        up("""
        CREATE TRIGGER immutable_proposal_executions BEFORE UPDATE OR DELETE ON keyfleet_app.proposal_executions
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down("DROP TRIGGER immutable_proposal_executions ON keyfleet_app.proposal_executions;")
      end

      statement :untruncatable_proposal_executions_trigger do
        up("""
        CREATE TRIGGER untruncatable_proposal_executions BEFORE TRUNCATE ON keyfleet_app.proposal_executions
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down(
          "DROP TRIGGER untruncatable_proposal_executions ON keyfleet_app.proposal_executions;"
        )
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false
      accept [:fleet_id, :executor, :block_number, :block_hash, :transaction_hash, :log_index]

      argument :proposal_number, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: @max_bigint]

      upsert? true
      upsert_identity :unique_chain_event
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
      change KeyFleet.Proposals.Changes.FindProposal
      change KeyFleet.Proposals.Changes.RecordOnce
    end

    # What was recorded from a stretch of the fleet's blocks, so a second
    # reading of the same stretch can be checked against it.
    read :recorded_in_blocks do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :from_block, :integer, allow_nil?: false
      argument :to_block, :integer, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and block_number >= ^arg(:from_block) and
                 block_number <= ^arg(:to_block)
             )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :executor, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    for field <- [:block_number, :log_index] do
      attribute field, :integer,
        allow_nil?: false,
        public?: true,
        constraints: [min: 0, max: @max_bigint]
    end

    for field <- [:block_hash, :transaction_hash] do
      attribute field, :string,
        allow_nil?: false,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]
    end

    attribute :record_seq, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    attribute :observed_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end

    belongs_to :proposal, KeyFleet.Proposals.Proposal do
      allow_nil? false
      public? true
    end
  end

  identities do
    # A proposal executes once.
    identity :unique_execution, [:proposal_id]
    identity :unique_chain_event, [:transaction_hash, :log_index]
    identity :unique_record_seq, [:fleet_id, :record_seq]
  end
end
