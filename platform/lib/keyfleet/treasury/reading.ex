defmodule Keyfleet.Treasury.Reading do
  @moduledoc """
  A fleet's balances as its contracts held them at one block: the shared
  money and reward backing of each token `Keyfleet.Chain.TreasuryReader`
  reads, the Cascade completion reserve and the protocol share owed.

  `Keyfleet.Chain.TreasuryReader` reads them every minute at the
  head's block and keeps only the latest reading of each fleet: a reading of
  the block kept, or of an earlier one, is ignored, and comes back marked
  `upsert_skipped` in its metadata.
  """
  use Ash.Resource,
    domain: Keyfleet.Treasury,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "treasury_readings"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:block_hash, "treasury_readings_block_hash_shape",
        check: "block_hash ~ '^0x[0-9a-f]{64}$'"
      )

      for field <- [:block_number, :cascade_reserve, :protocol_share_owed] do
        check_constraint(field, "treasury_readings_nonnegative_#{field}", check: "#{field} >= 0")
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false

      accept [
        :fleet_id,
        :block_number,
        :block_hash,
        :block_time,
        :cascade_reserve,
        :protocol_share_owed,
        :assets
      ]

      upsert? true
      upsert_identity :unique_fleet

      upsert_fields [
        :block_number,
        :block_hash,
        :block_time,
        :cascade_reserve,
        :protocol_share_owed,
        :assets
      ]

      upsert_condition expr(upsert_conflict(:block_number) > block_number)
      return_skipped_upsert? true
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

    # The block read, and its time on the chain.
    attribute :block_number, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: @max_bigint]

    attribute :block_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

    attribute :block_time, :utc_datetime_usec, allow_nil?: false, public?: true

    # USDC, in atomic units: held back for the next Cascade level, and owed to
    # the Regents Safe.
    for field <- [:cascade_reserve, :protocol_share_owed] do
      attribute field, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    end

    # USDC, the one income token, then each token a payment proposal not yet
    # carried out names, as `Keyfleet.Chain.TreasuryReader` reads them.
    attribute :assets, {:array, Keyfleet.Treasury.AssetBalance},
      allow_nil?: false,
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
    identity :unique_fleet, [:fleet_id]
  end
end
