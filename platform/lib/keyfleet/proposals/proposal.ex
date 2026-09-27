defmodule Keyfleet.Proposals.Proposal do
  @moduledoc """
  One proposal of a fleet's vote, from its `ProposalCreated` log and, for a
  launch or a payment, the payload log beside it. Only the chain reader
  writes it, and nothing ever changes it.

  Every key is one vote, and a key's latest vote is the one that counts, so
  `yes_keys` and `no_keys` count the keys whose latest vote is yes or no.
  `keys_sold` is how many keys the fleet has sold, as far as its key history
  has been read.

  Its place on the chain is the `ProposalCreated` log's. `record_seq` is the
  fleet's count of proposal records when it was made.
  """
  use Ash.Resource,
    domain: Keyfleet.Proposals,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807
  @text_cap 65_536

  postgres do
    table "proposals"
    repo(Keyfleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:number, "proposals_positive_number", check: "number > 0")

      check_constraint(:kind, "proposals_kind",
        check: "kind IN ('decision', 'autolaunch', 'pay')"
      )

      check_constraint(:text, "proposals_text_fields",
        check:
          "num_nonnulls(text, text_bytes, text_sha256) = CASE kind WHEN 'autolaunch' THEN 0 ELSE 3 END"
      )

      check_constraint(:envelope_hash, "proposals_autolaunch_fields",
        check: "num_nonnulls(envelope_hash) = CASE kind WHEN 'autolaunch' THEN 1 ELSE 0 END"
      )

      check_constraint(:asset, "proposals_pay_fields",
        check: "num_nonnulls(asset, amount, recipient) = CASE kind WHEN 'pay' THEN 3 ELSE 0 END"
      )

      check_constraint(:text, "proposals_text_cap",
        check: "octet_length(text) = least(text_bytes, #{@text_cap})"
      )

      check_constraint(:amount, "proposals_nonnegative_amount", check: "amount >= 0")

      for field <- [:proposer, :asset, :recipient] do
        check_constraint(field, "proposals_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{40}$'"
        )
      end

      for field <- [:digest, :text_sha256, :envelope_hash, :block_hash, :transaction_hash] do
        check_constraint(field, "proposals_#{field}_shape",
          check: "#{field} ~ '^0x[0-9a-f]{64}$'"
        )
      end

      for field <- [:opened_block, :block_number, :log_index] do
        check_constraint(field, "proposals_nonnegative_#{field}", check: "#{field} >= 0")
      end

      check_constraint(:record_seq, "proposals_positive_record_seq", check: "record_seq > 0")
    end

    custom_indexes do
      # What the second reading of the last blocks compares with.
      index([:fleet_id, :block_number])
      index([:fleet_id, :digest])
      index([:fleet_id, :envelope_hash])
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
        :kind,
        :proposer,
        :opened_block,
        :digest,
        :text,
        :text_bytes,
        :text_sha256,
        :envelope_hash,
        :asset,
        :amount,
        :recipient,
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
    # (from the newest when nil), newest first, `limit` at most, with the
    # start of their text and the name of the launch they propose.
    read :recorded_before do
      argument :fleet_id, :string, allow_nil?: false
      argument :before_seq, :integer, constraints: [min: 1, max: @max_bigint]
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 100]
      filter expr(fleet_id == ^arg(:fleet_id))

      prepare {Keyfleet.Preparations.NewestFirst,
               sort: [record_seq: :desc], before: [:before_seq]}

      prepare fn query, _context ->
        query
        |> Ash.Query.select([
          :id,
          :fleet_id,
          :number,
          :kind,
          :proposer,
          :asset,
          :amount,
          :recipient,
          :record_seq,
          :observed_at
        ])
        |> Ash.Query.load([:text_start, launch_envelope: launch_name()])
      end
    end

    # The fleet's launch proposals whose launch has not been read yet.
    read :launches_without_envelope do
      public? false
      argument :fleet_id, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and kind == :autolaunch and
                 not exists(launch_envelope, true)
             )

      prepare build(sort: [number: :asc])
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

    attribute :number, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:decision, :autolaunch, :pay]]

    attribute :proposer, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    # The block it was proposed in: a key that last moved before this block
    # may vote on it.
    attribute :opened_block, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: @max_bigint]

    for field <- [:digest, :text_sha256, :envelope_hash] do
      attribute field, :string,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]
    end

    # A Decision's or payment's text: its first 64 KiB as raw bytes, which need
    # not be valid text, beside the full length and the SHA-256 of all of it.
    attribute :text, :binary, public?: true
    attribute :text_bytes, :integer, public?: true, constraints: [min: 0, max: @max_bigint]

    # A payment's asset, amount in the asset's atomic units (any uint256) and
    # recipient.
    for field <- [:asset, :recipient] do
      attribute field, :string,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]
    end

    attribute :amount, :decimal, public?: true, constraints: [min: 0]

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
    has_one :launch_envelope, Keyfleet.Proposals.LaunchEnvelope, public?: true
  end

  aggregates do
    exists :executed?, :execution, public?: true
  end

  calculations do
    # The fleet's highest key number read: the contract numbers keys from 1
    # in the order it sells them and never burns one.
    calculate :keys_sold,
              :integer,
              expr(
                fragment(
                  "(SELECT coalesce(max(key.token_id), 0) FROM keyfleet_app.key_attachments AS key WHERE key.fleet_id = ?)",
                  fleet_id
                )
              ),
              public?: true

    calculate :yes_keys, :integer, {Keyfleet.Proposals.Calculations.LatestVotes, support: true},
      public?: true

    calculate :no_keys, :integer, {Keyfleet.Proposals.Calculations.LatestVotes, support: false},
      public?: true

    # The first bytes of a decision's or payment's text, enough for 160
    # characters, cut in the database so a page never loads whole texts.
    calculate :text_start, :binary, expr(fragment("substring(? from 1 for 640)", text)),
      public?: true
  end

  @doc "What a line about a launch loads of it: its name and symbol."
  def launch_name,
    do: Ash.Query.select(Keyfleet.Proposals.LaunchEnvelope, [:id, :proposal_id, :name, :symbol])

  identities do
    identity :unique_number, [:fleet_id, :number]
    identity :unique_chain_event, [:transaction_hash, :log_index]
    identity :unique_record_seq, [:fleet_id, :record_seq]
  end
end
