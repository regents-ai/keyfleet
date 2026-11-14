defmodule KeyfleetWeb.AgentTools.Fundings do
  @moduledoc """
  Funding a fleet's treasury with USDC on Base, paid in NEAR, as an agent does
  it: pricing it (`quote`), starting one (`start`) and reading one with its
  latest state (`show`). Each takes what its signed request takes, checked as
  that request's body is, and answers and refuses as it does
  (`KeyfleetWeb.AgentTools.Run`, `KeyfleetWeb.AgentTools.Fundings.Answer`).
  The agent sends the NEAR from its own wallet; the site never holds or moves
  funds.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]

  actions do
    action :quote, :map do
      description "Prices funding a fleet's treasury with USDC on Base, paid in NEAR."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :usdc_amount, :integer, allow_nil?: false
      argument :refund_to, :string, allow_nil?: false, constraints: [max_length: 64, trim?: false]
      run {Run, tool: "fundings_quote"}
    end

    action :start, :map do
      description "Starts funding a fleet's treasury and answers where to send the NEAR."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :usdc_amount, :integer, allow_nil?: false
      argument :refund_to, :string, allow_nil?: false, constraints: [max_length: 64, trim?: false]
      run {Run, tool: "fundings_start"}
    end

    action :show, :map do
      description "One funding with its latest state and, once the USDC lands, its receipt."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet

      argument :funding_id, :string,
        allow_nil?: false,
        constraints: [max_length: 36, trim?: false]

      run {Run, tool: "fundings_show"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
      authorize_if Keyfleet.Agents.Connection.Listing
    end
  end
end
