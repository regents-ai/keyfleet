defmodule Keyfleet.Fundings.Funding do
  @moduledoc """
  One funding of a fleet's treasury paid in NEAR: the USDC asked, the
  treasury address it lands at, the NEAR account refunds go to, the quote as
  the service answered it, the deposit address the payer sends NEAR to, and
  how it stands, with the NEAR and Base transactions once the service names
  them.

  A member of the fleet (`Keyfleet.Access`, `:fundings`) prices and starts one
  and reads its status again; anyone who sees the fleet's treasury sees its
  fundings. The service is asked before the record is written and never
  inside a transaction (`Keyfleet.Fundings.Changes.AskQuote`,
  `Keyfleet.Fundings.Changes.ReadStatus`).
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Fundings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Fundings.Changes

  # At most 1,000 USDC in one funding, in USDC's six-decimal base units.
  @most 1_000_000_000
  # A NEAR account: named (`alice.near`, `team-1.alice.near`) or implicit
  # (64 hex characters).
  @near_account ~r/\A(?=.{2,64}\z)(([a-z\d]+[\-_])*[a-z\d]+\.)*([a-z\d]+[\-_])*[a-z\d]+\z/

  postgres do
    table "fundings"
    repo(Keyfleet.Repo)

    custom_indexes do
      index(["fleet_id", "inserted_at"], name: "fundings_fleet_index")
    end
  end

  actions do
    # The price of a funding, asked without starting one.
    action :price, :map do
      argument :fleet_id, :string, allow_nil?: false
      argument :usdc_amount, :integer, allow_nil?: false, constraints: [min: 1, max: @most]

      argument :refund_to, :string,
        allow_nil?: false,
        constraints: [match: @near_account, trim?: false]

      run Keyfleet.Fundings.Actions.Price
    end

    create :start do
      accept [:usdc_amount, :refund_to]
      argument :fleet_id, :string, allow_nil?: false

      change set_attribute(:fleet_id, arg(:fleet_id))
      change set_attribute(:started_by_account_id, actor(:human_account_id))
      change Keyfleet.Agents.Changes.RecordAuthority
      change Changes.AskQuote
    end

    read :read do
      primary? true
      public? false
    end

    # The fleet's latest twenty fundings, newest first.
    read :of_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [inserted_at: :desc, id: :desc], limit: 20)
    end

    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(fleet_id == ^arg(:fleet_id) and id == ^arg(:id))
    end

    # Reads how the deposit stands from the service and records it. A
    # funding that has arrived, been refunded or failed is not asked again.
    update :refresh do
      accept []
      require_atomic? false
      change Changes.ReadStatus
    end
  end

  policies do
    policy action([:price, :start, :refresh]) do
      authorize_if {Keyfleet.Access.Check, write: :fundings, scope: :fleet_id}
    end

    policy action([:read, :of_fleet, :in_fleet]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :fleet_id, :string, allow_nil?: false, public?: true, writable?: false

    attribute :usdc_amount, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @most]

    # The fleet's treasury on Base, never an address anyone typed.
    attribute :recipient, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :refund_to, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @near_account, trim?: false]

    # The NEAR to send, in yoctoNEAR and as the service writes it.
    attribute :near_in, :decimal, allow_nil?: false, public?: true, writable?: false
    attribute :near_in_formatted, :string, allow_nil?: false, public?: true, writable?: false
    attribute :time_estimate_s, :integer, public?: true, writable?: false
    attribute :deadline, :utc_datetime_usec, public?: true, writable?: false
    attribute :deposit_address, :string, allow_nil?: false, public?: true, writable?: false

    attribute :state, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: :pending_deposit,
      constraints: [one_of: [:pending_deposit, :processing, :success, :refunded, :failed]]

    # The deposit on NEAR and the USDC sent on Base, once the service names them.
    attribute :origin_tx, :string, public?: true, writable?: false
    attribute :destination_tx, :string, public?: true, writable?: false
    # When the service first read it arrived, refunded or failed.
    attribute :finished_at, :utc_datetime_usec, public?: true, writable?: false

    # Who started it: the person's account, or the agent's wallet and the
    # person it is paired with.
    attribute :started_by_account_id, :integer, public?: true, writable?: false
    attribute :acting_agent_wallet, :string, public?: true, writable?: false
    attribute :beneficiary_privy_user_id, :string, writable?: false, sensitive?: true
    attribute :agent_pairing_id, :uuid, writable?: false

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  @doc "The states a funding ends in."
  def final_states, do: [:success, :refunded, :failed]
end
