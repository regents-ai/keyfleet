defmodule Keyfleet.Proposals.LaunchEnvelope do
  @moduledoc """
  The launch a recorded Autolaunch proposal approves, read from the vote
  contract's `launchEnvelope` at the proposal's own block, and kept only when
  its hash is the proposal's envelope hash. Only the chain reader writes it,
  and nothing ever changes it.

  The five text fields are the bytes the contract holds, which need not be
  valid text. `record_seq` is the fleet's count of proposal and budget records
  when it was made, so its arrival reads as a change to the proposal.
  """
  use Ash.Resource,
    domain: Keyfleet.Proposals,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807
  @texts [:name, :symbol, :description, :website, :image]

  postgres do
    table "proposal_launch_envelopes"
    repo(Keyfleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:required_regent_raised, "proposal_launch_envelopes_positive_raise",
        check: "required_regent_raised > 0"
      )

      check_constraint(:record_seq, "proposal_launch_envelopes_positive_record_seq",
        check: "record_seq > 0"
      )
    end

    custom_statements do
      statement :immutable_proposal_launch_envelopes_trigger do
        up("""
        CREATE TRIGGER immutable_proposal_launch_envelopes BEFORE UPDATE OR DELETE ON keyfleet_app.proposal_launch_envelopes
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down(
          "DROP TRIGGER immutable_proposal_launch_envelopes ON keyfleet_app.proposal_launch_envelopes;"
        )
      end

      statement :untruncatable_proposal_launch_envelopes_trigger do
        up("""
        CREATE TRIGGER untruncatable_proposal_launch_envelopes BEFORE TRUNCATE ON keyfleet_app.proposal_launch_envelopes
        FOR EACH STATEMENT EXECUTE FUNCTION keyfleet_app.refuse_proposal_record_change();
        """)

        down(
          "DROP TRIGGER untruncatable_proposal_launch_envelopes ON keyfleet_app.proposal_launch_envelopes;"
        )
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false
      accept [:fleet_id, :proposal_id, :required_regent_raised | @texts]
      upsert? true
      upsert_identity :unique_proposal
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
      change {Keyfleet.Chain.Changes.RecordOnce, identity: [:proposal_id], number: :proposal_seq}
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

    for field <- @texts do
      attribute field, :binary, allow_nil?: false, public?: true
    end

    # The REGENT the launch's auction must raise to graduate, in atomic units.
    attribute :required_regent_raised, :decimal,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

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

    belongs_to :proposal, Keyfleet.Proposals.Proposal do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_proposal, [:proposal_id]
    identity :unique_record_seq, [:fleet_id, :record_seq]
  end
end
