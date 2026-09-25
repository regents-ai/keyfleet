defmodule Keyfleet.Agents do
  @moduledoc "Wallet-owned agent profiles, independent of NFT authority."
  use Ash.Domain

  resources do
    resource Keyfleet.Agents.AgentProfile do
      define :ensure_profile, action: :ensure_profile
      define :get_my_profile, action: :get_my_profile, not_found_error?: false
      define :edit_my_profile, action: :edit_my_profile
      define :agents_here, action: :here_in_fleet, args: [:fleet_id]
    end
  end

  @doc "How many agents run at least one of the fleet's keys right now."
  def count_agents_here!(fleet_id) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleet, %{fleet_id: fleet_id})
    |> Ash.count!()
  end
end
