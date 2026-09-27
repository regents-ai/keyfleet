defmodule Keyfleet.Chain.Cursor do
  @moduledoc """
  How far one fleet's key history has been read from the chain, and whether it
  can be trusted right now.

  Base confirms a block in about two seconds and nothing here waits for more:
  ownership is recorded at the head. A later reading that disagrees with what
  was recorded sets `rescan_from` and stops the fleet there until an operator
  has corrected the record by hand.

  It also numbers the fleet's proposal and budget records (`proposal_seq`),
  its key reveals (`reveal_seq`) and its ownership epochs (`ownership_seq`).
  """
  use Ash.Resource,
    domain: Keyfleet.Chain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Ownership is fresh while the head was read within this many seconds, and
  # the record reaches to within this many blocks of it (ten minutes of Base).
  @fresh_seconds 120
  @fresh_blocks 300

  postgres do
    table "chain_cursors"
    repo(Keyfleet.Repo)

    check_constraints do
      for field <- [
            :next_block,
            :head_block,
            :rescan_from,
            :proposal_seq,
            :reveal_seq,
            :ownership_seq
          ] do
        check_constraint(field, "chain_cursors_nonnegative_#{field}", check: "#{field} >= 0")
      end

      check_constraint(:head_block_hash, "chain_cursors_head_hash_shape",
        check: "head_block_hash ~ '^0x[0-9a-f]{64}$'"
      )
    end
  end

  actions do
    defaults [:read]

    read :fresh do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and fresh?)
      get? true
    end

    # Starts reading a fleet at its deployment block; an existing cursor is
    # returned untouched.
    create :open do
      public? false
      accept [:fleet_id, :next_block]
      upsert? true
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
    end

    # The fleet's cursor while it still stands at `next_block` and the fleet
    # is not stopped. A pass writes the cursor only through this, so it never
    # undoes an operator's correction or another pass's progress.
    read :standing do
      argument :fleet_id, :string, allow_nil?: false
      argument :next_block, :integer, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and next_block == ^arg(:next_block) and
                 is_nil(rescan_from)
             )
    end

    update :advance do
      public? false
      accept [:next_block, :head_block, :head_block_hash, :observed_at]
      require_attributes [:next_block, :head_block, :head_block_hash, :observed_at]
    end

    # Stops the fleet at `block`, or keeps an earlier stop, in one update, so
    # an operator always sees the earliest block where the chain disagreed.
    update :flag_divergence do
      public? false
      accept []
      argument :block, :integer, allow_nil?: false, constraints: [min: 0]

      change atomic_update(
               :rescan_from,
               expr(
                 if is_nil(rescan_from) or rescan_from > ^arg(:block) do
                   ^arg(:block)
                 else
                   rescan_from
                 end
               )
             )
    end

    update :clear_divergence do
      public? false
      accept []
      change set_attribute(:rescan_from, nil)
      # Fresh again only once a new pass has read the chain.
      change set_attribute(:observed_at, nil)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:open, :advance, :flag_divergence, :clear_divergence]) do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    # The first block not yet read.
    attribute :next_block, :integer, allow_nil?: false, public?: true, constraints: [min: 0]

    attribute :head_block, :integer, public?: true, constraints: [min: 0]

    attribute :head_block_hash, :string,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

    # When the head was last read.
    attribute :observed_at, :utc_datetime_usec, public?: true

    # The block where the chain was found to disagree with the record.
    attribute :rescan_from, :integer, public?: true, constraints: [min: 0]

    # The last number given to one of the fleet's proposal, vote, execution,
    # income split or budget payment records. It is moved only by `Keyfleet.Chain.take_proposal_seq!/1`.
    attribute :proposal_seq, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      constraints: [min: 0]

    # The last number given to one of the fleet's key reveals. It is moved only
    # by `Keyfleet.Chain.take_reveal_seq!/1`.
    attribute :reveal_seq, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      constraints: [min: 0]

    # The last number given to one of the fleet's ownership epochs. It is moved
    # only by `Keyfleet.Chain.take_ownership_seq!/1`.
    attribute :ownership_seq, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      constraints: [min: 0]
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      primary_key? true
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :fresh?,
              :boolean,
              expr(
                is_nil(rescan_from) and not is_nil(observed_at) and
                  observed_at > ago(@fresh_seconds, :second) and
                  head_block - next_block < @fresh_blocks
              )
  end
end
