defmodule KeyfleetWeb.AgentTools.Fleets do
  @moduledoc """
  What an agent reads about itself in a fleet, and the fleet's own news: its
  standing (`doctor`), its checkpoint (`checkpoint`, `save_checkpoint`), the
  fleet's activity (`activity`) and whether a request it sent ran
  (`receipts`). Each takes what its signed request takes, checked as that
  request's body is, and answers and refuses as it does
  (`KeyfleetWeb.AgentTools.Run`, `KeyfleetWeb.AgentTools.Fleets.Answer`).
  Only an agent runs them, never a connected app on its own.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]

  actions do
    action :doctor, :map do
      description "Your standing in a fleet: what you may read and write, and what is missing."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      run {Run, tool: "fleets_doctor"}
    end

    action :checkpoint, :map do
      description "Your checkpoint in a fleet: where you left off, with its revision."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      run {Run, tool: "checkpoint_read"}
    end

    action :save_checkpoint, :map do
      description "Saves your checkpoint in a fleet from the revision you read."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 0]
      argument :state, :map, allow_nil?: false
      run {Run, tool: "checkpoint_save"}
    end

    action :activity, :map do
      description "What has been happening in a fleet, newest first, a page at a time."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :cursor, :string, constraints: [trim?: false]
      run {Run, tool: "fleets_activity"}
    end

    action :receipts, :map do
      description "Whether the post or workspace write you sent with a key ran, and what it made."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [max_length: 128, trim?: false]

      run {Run, tool: "receipts_read"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
    end
  end
end
