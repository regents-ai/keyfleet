defmodule KeyfleetWeb.AgentTools.Budgets do
  @moduledoc """
  A project's budget for Patchbay assists as an agent reads and spends it:
  reading the project's budget with its purchases (`show`), and as a Key
  proposing a purchase against it, deciding
  another Key's proposal, recording what was bought and recording whether
  it worked (`propose`, `decide`, `receipt`, `result`). Each takes what its
  signed request takes, checked as that request's body is, and answers and
  refuses as it does (`KeyfleetWeb.AgentTools.Run`,
  `KeyfleetWeb.AgentTools.Budgets.Answer`). Only an agent runs them, never a
  connected app on its own; the budgets' own policies decide what it may do.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]
  @project [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32]
  @purchase [max_length: 36, trim?: false]
  @key [min: 1]
  @link [match: ~r/\Ahttps:\/\/\S+\z/, max_length: 2048, trim?: false]

  actions do
    action :show, :map do
      description "A project's budget, with every purchase made against it."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      run {Run, tool: "budget_show"}
    end

    action :propose, :map do
      description "Proposes buying a Patchbay assist from a project's budget."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :as_key, :integer, allow_nil?: false, constraints: @key

      argument :purpose, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200, trim?: false]

      argument :assist_url, :string, allow_nil?: false, constraints: @link
      argument :price_usdc, :integer, allow_nil?: false, constraints: [min: 1]
      run {Run, tool: "purchases_propose"}
    end

    action :decide, :map do
      description "Approves or refuses another Key's proposed purchase."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :purchase_id, :string, allow_nil?: false, constraints: @purchase
      argument :as_key, :integer, allow_nil?: false, constraints: @key
      argument :approve, :boolean, allow_nil?: false
      argument :reason, :string, constraints: [max_length: 200, trim?: false]
      run {Run, tool: "purchases_decide"}
    end

    action :receipt, :map do
      description "Records the Patchbay receipt for an approved purchase you proposed."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :purchase_id, :string, allow_nil?: false, constraints: @purchase
      argument :as_key, :integer, allow_nil?: false, constraints: @key
      argument :receipt_url, :string, allow_nil?: false, constraints: @link
      argument :payment_tx, :string, constraints: [max_length: 100, trim?: false]
      run {Run, tool: "purchases_receipt"}
    end

    action :result, :map do
      description "Records whether another Key's bought assist worked."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :purchase_id, :string, allow_nil?: false, constraints: @purchase
      argument :as_key, :integer, allow_nil?: false, constraints: @key
      argument :worked, :boolean, allow_nil?: false

      argument :note, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200, trim?: false]

      argument :evidence_url, :string, constraints: @link
      run {Run, tool: "purchases_result"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
      authorize_if Keyfleet.Agents.Connection.Listing
    end
  end
end
