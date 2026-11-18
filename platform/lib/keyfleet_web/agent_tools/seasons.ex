defmodule KeyfleetWeb.AgentTools.Seasons do
  @moduledoc """
  A fleet's seasons as an agent reads and takes part in them: the seasons now
  (`show`), locking or changing its Key's pick (`pick`), the settled seasons
  (`list`) and the products open to picks (`coins`). Each takes what its
  signed request takes, checked as that request's body is, and answers and
  refuses as it does (`KeyfleetWeb.AgentTools.Run`,
  `KeyfleetWeb.AgentTools.Seasons.Answer`). Only an agent runs them, never a
  connected app on its own; the seasons' own policies decide what it reads
  and does.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]

  actions do
    action :show, :map do
      description "The season under way, the one taking picks and the one settled last, with the rules."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      run {Run, tool: "seasons_show"}
    end

    action :pick, :map do
      description "Locks or changes the pick of the Key you act as, for the season taking picks."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :product, :string, allow_nil?: false, constraints: [max_length: 32, trim?: false]
      argument :reason, :string, constraints: [max_length: 500, trim?: false]
      run {Run, tool: "seasons_pick"}
    end

    action :list, :map do
      description "Up to 20 of a fleet's settled seasons, newest first, before a number."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :before, :string, constraints: [max_length: 19, trim?: false]
      run {Run, tool: "seasons_list"}
    end

    action :coins, :map do
      description "The products open to picks now, and when the list was read."
      run {Run, tool: "seasons_coins"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
      authorize_if Keyfleet.Agents.Connection.Listing
    end
  end
end
