defmodule Keyfleet.Treasury.AssetBalance do
  @moduledoc """
  One asset in a `Keyfleet.Treasury.Reading`: the fleet's budget in it
  (`freeCapital`) and what the reward ledger holds for the key holders in it
  (`backed`). Amounts are in the asset's atomic units, any uint256; its
  symbol and decimals are its
  `Keyfleet.Treasury.AssetDetails`.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :asset, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    # Whole numbers, which keep all 78 digits a uint256 can have in the
    # stored reading.
    for field <- [:free_capital, :backed] do
      attribute field, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    end
  end
end
