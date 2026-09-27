defmodule Keyfleet.Treasury.BudgetPayment do
  @moduledoc """
  One `BudgetPaid` log: an approved payment paid out of the fleet's budget, with
  the match it set aside: `share` for each key sold that did not vote yes,
  `matched` in all, which those keys collect from the vote contract. Amounts
  are in the asset's atomic units, any uint256. Only the chain reader writes
  it, and nothing ever changes it.

  `record_seq` is the fleet's count of proposal and budget records when it
  was made.
  """
  use Ash.Resource,
    domain: Keyfleet.Treasury,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "budget_payments"
    repo(Keyfleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      for field <- [:asset, :recipient] do
        check_constraint(field, "budget_payments_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{40}$'"
        )
      end

      for field <- [:amount, :share, :matched] do
        check_constraint(field, "budget_payments_nonnegative_#{field}", check: "#{field} >= 0")
      end

      for field <- [:block_hash, :transaction_hash] do
        check_constraint(field, "budget_payments_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{64}$'"
        )
      end

      for field <- [:block_number, :log_index] do
        check_constraint(field, "budget_payments_nonnegative_#{field}", check: "#{field} >= 0")
      end

      check_constraint(:record_seq, "budget_payments_positive_record_seq",
        check: "record_seq > 0"
      )
    end

    custom_indexes do
      # What the second reading of the last blocks compares with.
      index([:fleet_id, :block_number])
    end

    custom_statements do
      statement :immutable_budget_payments_trigger do
        up("""
        CREATE TRIGGER immutable_budget_payments BEFORE UPDATE OR DELETE ON keyfleet_app.budget_payments
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down("DROP TRIGGER immutable_budget_payments ON keyfleet_app.budget_payments;")
      end

      statement :untruncatable_budget_payments_trigger do
        up("""
        CREATE TRIGGER untruncatable_budget_payments BEFORE TRUNCATE ON keyfleet_app.budget_payments
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down("DROP TRIGGER untruncatable_budget_payments ON keyfleet_app.budget_payments;")
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false

      accept [
        :fleet_id,
        :asset,
        :recipient,
        :amount,
        :share,
        :matched,
        :block_number,
        :block_hash,
        :transaction_hash,
        :log_index
      ]

      upsert? true
      upsert_identity :unique_chain_event
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      change {Keyfleet.Chain.Changes.RecordOnce,
              identity: [:transaction_hash, :log_index],
              number: :proposal_seq,
              block: :block_number}
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
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    for field <- [:asset, :recipient] do
      attribute field, :string,
        allow_nil?: false,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]
    end

    for field <- [:amount, :share, :matched] do
      attribute field, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    end

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
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_chain_event, [:transaction_hash, :log_index]
    identity :unique_record_seq, [:fleet_id, :record_seq]
  end
end
