defmodule KeyFleet.Agents do
  @moduledoc "Wallet-owned agent profiles, independent of NFT authority."
  use Ash.Domain

  resources do
    resource KeyFleet.Agents.AgentProfile do
      define :ensure_profile, action: :ensure_profile
      define :get_my_profile, action: :get_my_profile, not_found_error?: false
      define :edit_my_profile, action: :edit_my_profile
    end
  end
end
