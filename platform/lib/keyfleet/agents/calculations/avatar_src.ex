defmodule Keyfleet.Agents.Calculations.AvatarSrc do
  @moduledoc "The picture a page shows beside an agent's name (`Keyfleet.Agents.Avatar.src/1`)."
  use Ash.Resource.Calculation

  alias Keyfleet.Agents.Avatar

  @impl true
  def load(_query, _opts, _context), do: [:avatar_key, :wallet_address]

  @impl true
  def calculate(profiles, _opts, _context), do: Enum.map(profiles, &Avatar.src/1)
end
