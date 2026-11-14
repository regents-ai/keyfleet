defmodule Keyfleet.Budgets.Purchase do
  @moduledoc """
  One Patchbay assist bought from a project's budget, through four steps,
  each recording the Key that took it and when:

    1. `propose`: a Key proposes it, with what it is for, the assist's link
       and its price in USDC base units. State `proposed`.
    2. `decide`: a different Key approves it, `approved`, or refuses it,
       `refused`, with its reason. The site refuses an approval that costs
       more than the budget has left (`over_budget`) or comes after it
       expired (`budget_expired`) and records the purchase as refused with
       that reason.
    3. `receipt`: the proposing Key records Patchbay's receipt link and, if
       it has one, the payment's transaction id. State `bought`.
    4. `result`: a Key other than the proposer records whether the fix
       worked, `worked` or `failed`, with a note and, if it has one, a link
       to its evidence.

  The site does not check the receipt or the payment.
  """
  use Ash.Resource,
    domain: Keyfleet.Budgets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Budgets.{Https, Steps}
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Validations.{FreshOwnership, KnownFleet}

  @bigint 9_223_372_036_854_775_807
  @states [:proposed, :approved, :refused, :bought, :worked, :failed]
  @refusals [:over_budget, :budget_expired, :refused]
  # A short line of text, never a control character.
  @line [min_length: 1, max_length: 200, match: ~r/\A[^\x00-\x1f\x7f]*\z/]

  postgres do
    table "purchases"
    repo(Keyfleet.Repo)

    custom_indexes do
      index([:budget_id, :inserted_at])
    end

    check_constraints do
      check_constraint(:price_usdc, "purchases_price_positive", check: "price_usdc > 0")

      check_constraint(:state, "purchases_state",
        check: "state IN ('proposed', 'approved', 'refused', 'bought', 'worked', 'failed')"
      )
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    # One purchase, its row held until the transaction ends.
    read :locked do
      public? false
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    create :record do
      public? false
      accept [:fleet_id, :budget_id, :purpose, :assist_url, :price_usdc, :proposed_by_key]
      change set_attribute(:state, :proposed)
    end

    update :record_step do
      public? false

      accept [
        :state,
        :decided_by_key,
        :decided_at,
        :refusal_code,
        :refusal_reason,
        :receipt_url,
        :payment_tx,
        :bought_at,
        :worked,
        :result_note,
        :evidence_url,
        :checked_by_key,
        :checked_at
      ]
    end

    # A Key proposes buying an assist from the project's open budget.
    action :propose, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :project, :string, allow_nil?: false, constraints: [trim?: false]
      argument :purpose, :string, allow_nil?: false, constraints: @line
      argument :assist_url, :string, allow_nil?: false, constraints: [trim?: false]
      argument :price_usdc, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      validate KnownFleet
      validate {Https, field: :assist_url}
      validate FreshOwnership, only_when_valid?: true
      run {Steps, step: :propose}
    end

    # A Key other than the proposer approves or refuses it.
    action :decide, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :id, :uuid, allow_nil?: false
      argument :approve, :boolean, allow_nil?: false
      argument :reason, :string, constraints: @line
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Steps, step: :decide}
    end

    # The proposing Key records Patchbay's receipt for an approved purchase.
    action :receipt, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :id, :uuid, allow_nil?: false
      argument :receipt_url, :string, allow_nil?: false, constraints: [trim?: false]
      argument :payment_tx, :string, constraints: [max_length: 100]
      validate KnownFleet
      validate {Https, field: :receipt_url}
      validate FreshOwnership, only_when_valid?: true
      run {Steps, step: :receipt}
    end

    # A Key other than the proposer records whether the fix worked.
    action :result, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :id, :uuid, allow_nil?: false
      argument :worked, :boolean, allow_nil?: false
      argument :note, :string, allow_nil?: false, constraints: @line
      argument :evidence_url, :string, constraints: [trim?: false]
      validate KnownFleet
      validate {Https, field: :evidence_url}
      validate FreshOwnership, only_when_valid?: true
      run {Steps, step: :result}
    end
  end

  policies do
    policy action([:propose, :decide, :receipt, :result]) do
      authorize_if KeyActor
    end

    # A budget's members read its purchases with it.
    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if accessing_from(Keyfleet.Budgets.Budget, :purchases)
    end

    policy action([:locked, :record, :record_step]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :fleet_id, :string, allow_nil?: false, public?: true
    attribute :purpose, :string, allow_nil?: false, public?: true, constraints: @line
    attribute :assist_url, :string, allow_nil?: false, public?: true
    attribute :price_usdc, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :state, :atom, allow_nil?: false, public?: true, constraints: [one_of: @states]
    attribute :proposed_by_key, :integer, allow_nil?: false, public?: true
    attribute :decided_by_key, :integer, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    # Why it was refused: by the site, `over_budget` or `budget_expired`, or
    # by the deciding Key, `refused`, with its reason.
    attribute :refusal_code, :atom, public?: true, constraints: [one_of: @refusals]
    attribute :refusal_reason, :string, public?: true
    attribute :receipt_url, :string, public?: true
    attribute :payment_tx, :string, public?: true
    attribute :bought_at, :utc_datetime_usec, public?: true
    # Whether the fix worked, as the checking Key found it.
    attribute :worked, :boolean, public?: true
    attribute :result_note, :string, public?: true
    attribute :evidence_url, :string, public?: true
    attribute :checked_by_key, :integer, public?: true
    attribute :checked_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :budget, Keyfleet.Budgets.Budget, allow_nil?: false, public?: true
  end
end
