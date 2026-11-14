defmodule Keyfleet.Budgets.Budget do
  @moduledoc """
  A project's budget: the Key that opened it (`sponsor_key`), its limit in
  USDC base units, when it expires and, as given, where the money came from
  (`source`: free words or a treasury funding's id, never looked up).

  `spent_usdc` is what its approved purchases cost, an approved, bought or
  checked one; `remaining_usdc` is the limit less that. An expired budget
  approves nothing. A project has one open budget at a time: opening one
  holds the project's row until it is saved (`Keyfleet.Budgets.Steps`).
  """
  use Ash.Resource,
    domain: Keyfleet.Budgets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Budgets.Steps
  alias Keyfleet.Graph.Checks.{KeyActor, KeyReader}
  alias Keyfleet.Graph.Validations.{FreshOwnership, KnownFleet}

  @bigint 9_223_372_036_854_775_807
  @name [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32, trim?: false]
  # The states of a purchase whose price the budget has spent.
  @spending [:approved, :bought, :worked, :failed]

  @doc "The states of a purchase whose price the budget has spent."
  def spending, do: @spending

  postgres do
    table "budgets"
    repo(Keyfleet.Repo)

    custom_indexes do
      index([:fleet_id, :project, :inserted_at])
    end

    check_constraints do
      check_constraint(:limit_usdc, "budgets_limit_positive", check: "limit_usdc > 0")
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    # The project's latest budget, open or expired, with what it spent and
    # every purchase, oldest first.
    read :latest do
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false, constraints: [trim?: false]
      get? true
      filter expr(fleet_id == ^arg(:fleet_id) and project == ^arg(:project))

      prepare build(
                sort: [inserted_at: :desc],
                limit: 1,
                load: [:spent_usdc, :remaining_usdc, :expired?, :purchases]
              )
    end

    # The project's budget that has not expired, if it has one.
    read :open_on do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false, constraints: [trim?: false]
      get? true

      filter expr(
               fleet_id == ^arg(:fleet_id) and project == ^arg(:project) and expires_at > now()
             )
    end

    # One budget, its row held until the transaction ends, so approvals
    # against it take turns.
    read :locked do
      public? false
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    create :record do
      public? false
      accept [:fleet_id, :project, :sponsor_key, :limit_usdc, :expires_at, :source]
    end

    # A Key opens a budget on one of the fleet's active projects.
    action :open, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :project, :string, allow_nil?: false, constraints: @name
      argument :limit_usdc, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :expires_at, :utc_datetime_usec, allow_nil?: false
      argument :source, :string, constraints: [max_length: 200]
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Steps, step: :open}
    end
  end

  policies do
    policy action(:open) do
      authorize_if KeyActor
    end

    policy action(:latest) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if KeyReader
    end

    policy action([:read, :open_on, :locked, :record]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :fleet_id, :string, allow_nil?: false, public?: true
    attribute :project, :string, allow_nil?: false, public?: true, constraints: @name
    # The Key that opened it.
    attribute :sponsor_key, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :limit_usdc, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    # Where the money came from, as the sponsor gave it.
    attribute :source, :string, public?: true, constraints: [max_length: 200]
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    has_many :purchases, Keyfleet.Budgets.Purchase do
      public? true
      sort inserted_at: :asc
    end
  end

  aggregates do
    sum :spent_usdc, :purchases, :price_usdc do
      public? true
      filter expr(state in ^@spending)
      default 0
    end
  end

  calculations do
    calculate :remaining_usdc, :integer, expr(limit_usdc - spent_usdc), public?: true
    calculate :expired?, :boolean, expr(expires_at <= now()), public?: true
  end
end
