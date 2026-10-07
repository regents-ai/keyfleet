defmodule Keyfleet.Proposals.Proposal do
  @moduledoc """
  One proposal of a fleet's vote, from its `ProposalCreated` log and the
  renewal of its author key just before it, which says when it opened. Only
  the chain reader writes it, and nothing ever changes it.

  Its narrative is kept off the chain; `content_hash` is its hash, and
  `words` the narrative saved under it (`Keyfleet.Proposals.Words`). `calls`
  are the exact calls the treasury makes, in order, if it is carried out.
  `opening_count` is how many keys were present when it opened.

  Every key has one vote, and its latest is the one that counts, so
  `yes_keys`, `no_keys` and `abstain_keys` count the keys whose latest vote
  is that choice. `late_keys` counts the keys that voted without having been
  present when it opened, which the contract adds to the keys it needs more
  than half of. Where it stands is
  `Keyfleet.Proposals.status/2`.

  Its place on the chain is the `ProposalCreated` log's. `record_seq` is the
  fleet's count of proposal records when it was made.
  """
  use Ash.Resource,
    domain: Keyfleet.Proposals,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "proposals"
    repo(Keyfleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      for field <- [:number, :author_key] do
        check_constraint(field, "proposals_positive_#{field}", check: "#{field} > 0")
      end

      check_constraint(:proposer, "proposals_proposer_shape",
        check: "proposer ~ '^0x[0-9a-f]{40}$'"
      )

      for field <- [:proposal_hash, :content_hash, :block_hash, :transaction_hash] do
        check_constraint(field, "proposals_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{64}$'"
        )
      end

      for field <- [:opening_count, :open_revision, :block_number, :log_index] do
        check_constraint(field, "proposals_nonnegative_#{field}", check: "#{field} >= 0")
      end

      check_constraint(:closes_at, "proposals_times_in_order",
        check: "opened_at < closes_at AND closes_at <= execution_expiry"
      )

      check_constraint(:record_seq, "proposals_positive_record_seq", check: "record_seq > 0")
    end

    custom_indexes do
      # What the second reading of the last blocks compares with.
      index([:fleet_id, :block_number])
    end

    custom_statements do
      # Every proposal record table refuses changes, deletes and emptying with
      # this one function; only the chain reader inserts.
      statement :immutable_proposal_records_function do
        up("""
        CREATE FUNCTION keyfleet_app.refuse_proposal_record_change() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION '% records cannot be changed or deleted', TG_TABLE_NAME USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.refuse_proposal_record_change();")
      end

      statement :immutable_proposals_trigger do
        up("""
        CREATE TRIGGER immutable_proposals BEFORE UPDATE OR DELETE ON keyfleet_app.proposals
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down("DROP TRIGGER immutable_proposals ON keyfleet_app.proposals;")
      end

      statement :untruncatable_proposals_trigger do
        up("""
        CREATE TRIGGER untruncatable_proposals BEFORE TRUNCATE ON keyfleet_app.proposals
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down("DROP TRIGGER untruncatable_proposals ON keyfleet_app.proposals;")
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false

      accept [
        :fleet_id,
        :number,
        :author_key,
        :proposer,
        :proposal_hash,
        :content_hash,
        :opened_at,
        :closes_at,
        :execution_expiry,
        :opening_count,
        :open_revision,
        :calls,
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

    # The fleet's highest proposal number recorded so far.
    read :latest_in_fleet do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [number: :desc], limit: 1, select: [:number])
      get? true
    end

    # The fleet's proposals recorded before its record number `before_seq`
    # (from the newest when nil), newest first, `limit` at most.
    read :recorded_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_seq, :integer, constraints: [min: 1, max: @max_bigint]
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 100]
      filter expr(fleet_id == ^arg(:fleet_id))

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [record_seq: :desc], before: [:before_seq]}

      prepare build(
                select: [
                  :id,
                  :fleet_id,
                  :number,
                  :author_key,
                  :proposer,
                  :content_hash,
                  :closes_at,
                  :calls,
                  :record_seq,
                  :observed_at
                ]
              )
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
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :number, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    # The key it was proposed with, and the wallet that proposed it: the key's
    # owner or an agent holding a shard of it.
    attribute :author_key, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    attribute :proposer, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    # The hash binding the whole proposal, which a signed ballot names, and the
    # hash of its narrative.
    for field <- [:proposal_hash, :content_hash] do
      attribute field, :string,
        allow_nil?: false,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]
    end

    # When it opened, when ballots stop, and the first second it can no
    # longer be carried out.
    for field <- [:opened_at, :closes_at, :execution_expiry] do
      attribute field, :utc_datetime, allow_nil?: false, public?: true
    end

    # How many keys were present when it opened, and the presence revision
    # the contract marked then.
    attribute :opening_count, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: 4_294_967_295]

    attribute :open_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: 281_474_976_710_655]

    attribute :calls, {:array, Keyfleet.Proposals.Call}, allow_nil?: false, public?: true

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

    has_many :votes, Keyfleet.Proposals.Vote, public?: true
    has_one :execution, Keyfleet.Proposals.Execution, public?: true
    has_one :cancellation, Keyfleet.Proposals.Cancellation, public?: true

    # Its words, as its fleet saved them under its fingerprint, if anyone did.
    has_one :words, Keyfleet.Proposals.Words do
      no_attributes? true
      filter expr(fleet_id == parent(fleet_id) and content_hash == parent(content_hash))
      public? true
    end
  end

  calculations do
    for choice <- [:yes, :no, :abstain] do
      calculate :"#{choice}_keys",
                :integer,
                {Keyfleet.Proposals.Calculations.LatestVotes, choice: choice},
                public?: true
    end

    calculate :late_keys, :integer, Keyfleet.Proposals.Calculations.LateKeys, public?: true
  end

  identities do
    identity :unique_number, [:fleet_id, :number]
    identity :unique_chain_event, [:transaction_hash, :log_index]
    identity :unique_record_seq, [:fleet_id, :record_seq]
  end
end
