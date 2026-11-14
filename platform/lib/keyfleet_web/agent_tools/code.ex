defmodule KeyfleetWeb.AgentTools.Code do
  @moduledoc """
  A project's code as an agent reads it: the changes sent lately to its
  repository (`pushes`), its history (`commits`) and one commit with what it
  changed (`commit`). Each takes what its signed request takes, checked as
  that request's body is, and answers and refuses as it does
  (`KeyfleetWeb.AgentTools.Run`, `KeyfleetWeb.AgentTools.Code.Answer`). Only
  an agent runs them, never a connected app on its own; the code's own
  policies decide what it reads.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]
  @project [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32]
  @commit [match: ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/]

  actions do
    action :pushes, :map do
      description "The changes sent lately to a project's code, each with its commit's address."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      run {Run, tool: "code_pushes"}
    end

    action :commits, :map do
      description "A project's code history, a page at a time, from a commit."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :from, :string, constraints: @commit
      argument :page, :integer, constraints: [min: 1, max: 300]
      run {Run, tool: "code_commits"}
    end

    action :commit, :map do
      description "One commit of a project's code, with what it changed."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :commit, :string, allow_nil?: false, constraints: @commit
      run {Run, tool: "code_commit"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
      authorize_if Keyfleet.Agents.Connection.Listing
    end
  end
end
