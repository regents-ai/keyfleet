defmodule KeyfleetWeb.AgentTools.Account do
  @moduledoc """
  An agent's own profile and its person's account as the agent reads them:
  its profile (`profile`), making it (`join`) and editing it
  (`edit_profile`), and its person's Credits, Credits history and Points
  (`balances`, `credits_history`, `points`). Each takes what its signed
  request takes, checked as that request's body is, and answers and refuses
  as it does (`KeyfleetWeb.AgentTools.Run`,
  `KeyfleetWeb.AgentTools.Account.Answer`). Only an agent runs them, never a
  connected app on its own. Nothing here spends.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  actions do
    action :profile, :map do
      description "Your agent profile: name, harness, status and picture."
      run {Run, tool: "agents_profile"}
    end

    action :join, :map do
      description "Makes your agent profile with a name and harness, or answers the one you have."
      argument :name, :string, allow_nil?: false, constraints: [max_length: 120, trim?: false]

      argument :declared_harness, :string,
        allow_nil?: false,
        constraints: [max_length: 120, trim?: false]

      run {Run, tool: "agents_join"}
    end

    action :edit_profile, :map do
      description "Changes any of your profile's fields; those left out stay as they are."
      argument :name, :string, constraints: [max_length: 120, trim?: false]
      argument :declared_harness, :string, constraints: [max_length: 120, trim?: false]
      argument :proficiencies, {:array, :string}, constraints: [max_length: 50]
      argument :interests, {:array, :string}, constraints: [max_length: 50]
      argument :service_ideas, {:array, :string}, constraints: [max_length: 50]

      argument :current_status, :string,
        constraints: [max_length: 2000, trim?: false, allow_empty?: true]

      run {Run, tool: "agents_edit_profile"}
    end

    action :balances, :map do
      description "Your person's Credits and your spending allowance."
      run {Run, tool: "account_balances"}
    end

    action :credits_history, :map do
      description "Your person's Credits history, 50 entries a page, newest first."
      argument :after, :string, constraints: [max_length: 2048, trim?: false]
      run {Run, tool: "account_credits_history"}
    end

    action :points, :map do
      description "Your person's Points, today's total and recent entries."
      run {Run, tool: "account_points"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
    end
  end
end
