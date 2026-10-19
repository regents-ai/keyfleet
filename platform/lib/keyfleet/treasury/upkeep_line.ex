defmodule Keyfleet.Treasury.UpkeepLine do
  @moduledoc """
  What one run of the upkeep (`Keyfleet.Treasury.Upkeep`) did with one step:
  pressed it (`:sent`, then `:done` once it landed), skipped it and why, or
  sent it and saw it fail. Only the upkeep writes it; anyone may read it.

  `run_id` names the run. `fleet_id` is the fleet the step is for, and nil
  for Turn into REGENT, which the REGENT buyer serves for every fleet, and for
  a line about the whole run, which has no `step` either: the run pressed
  nothing because an earlier transaction was still waiting
  (`:earlier_waiting`), or the node couldn't be read (`:unread`).
  `proposal` is the proposal a `:carry_out` line carries out. `opens_at` is
  when a step that isn't due yet (`:not_due`) opens.

  A pressed line keeps its signed transaction, saved before it was
  broadcast: `transaction_hash`, and `raw_transaction`, the bytes sent.
  `amount` is the USDC a Turn into REGENT turned, in base units, read from
  its receipt once it landed.
  A run leaves only the latest run's skipped lines, and no line is kept
  past 30 days.
  """
  use Ash.Resource,
    domain: Keyfleet.Treasury,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:run_split, :send_share, :convert, :carry_out]
  @outcomes [:sent, :done, :skipped, :failed]
  @reasons [
    :not_due,
    :no_keys_sold,
    :nothing_owed,
    :nothing_queued,
    :refused,
    :unread,
    :no_eth_for_gas,
    :fees_high,
    :earlier_waiting,
    :reverted,
    :not_sent
  ]
  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "treasury_upkeep_lines"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:transaction_hash, "treasury_upkeep_lines_transaction_hash_shape",
        check: "transaction_hash ~ '^0x[0-9a-f]{64}$'"
      )

      check_constraint(:raw_transaction, "treasury_upkeep_lines_raw_transaction_shape",
        check: "raw_transaction ~ '^0x02[0-9a-f]+$'"
      )

      # A skipped step was never signed; every other line was.
      check_constraint(:outcome, "treasury_upkeep_lines_signed",
        check:
          "num_nonnulls(transaction_hash, raw_transaction) = CASE outcome WHEN 'skipped' THEN 0 ELSE 2 END"
      )

      check_constraint(:reason, "treasury_upkeep_lines_reason",
        check: "(reason IS NULL) = (outcome IN ('sent', 'done'))"
      )

      check_constraint(:opens_at, "treasury_upkeep_lines_opens_at",
        check: "num_nonnulls(opens_at) = CASE reason WHEN 'not_due' THEN 1 ELSE 0 END"
      )

      check_constraint(:proposal, "treasury_upkeep_lines_proposal",
        check: "num_nonnulls(proposal) = CASE step WHEN 'carry_out' THEN 1 ELSE 0 END"
      )

      check_constraint(:amount, "treasury_upkeep_lines_amount",
        check: "amount IS NULL OR (step = 'convert' AND amount > 0)"
      )
    end
  end

  actions do
    defaults [:read]

    create :record do
      public? false

      accept [
        :run_id,
        :fleet_id,
        :step,
        :proposal,
        :outcome,
        :reason,
        :opens_at,
        :amount,
        :transaction_hash,
        :raw_transaction
      ]
    end

    # A sent line once its transaction landed, or once it is known never to.
    update :settle do
      public? false
      accept [:outcome, :reason, :amount]
    end

    read :unsettled do
      public? false
      filter expr(outcome == :sent)
      prepare build(sort: [inserted_at: :asc])
    end

    # What a run no longer keeps once it has finished: earlier runs' skipped
    # lines, and every line older than 30 days.
    read :forgettable do
      public? false
      argument :latest_run_id, :uuid, allow_nil?: false

      filter expr(
               (outcome == :skipped and run_id != ^arg(:latest_run_id)) or
                 inserted_at < ago(30, :day)
             )
    end

    destroy :forget do
      public? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid, allow_nil?: false, public?: true
    attribute :fleet_id, :string, public?: true
    attribute :step, :atom, public?: true, constraints: [one_of: @steps]

    attribute :proposal, :integer, public?: true, constraints: [min: 1, max: @max_bigint]

    attribute :outcome, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @outcomes]

    attribute :reason, :atom, public?: true, constraints: [one_of: @reasons]
    attribute :opens_at, :utc_datetime, public?: true
    attribute :amount, :integer, public?: true, constraints: [min: 1, max: @max_bigint]

    attribute :transaction_hash, :string,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

    attribute :raw_transaction, :string, constraints: [match: ~r/\A0x02[0-9a-f]+\z/, trim?: false]

    timestamps()
  end
end
