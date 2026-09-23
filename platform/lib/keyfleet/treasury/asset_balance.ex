defmodule KeyFleet.Treasury.AssetBalance do
  @moduledoc """
  One reward asset in a `KeyFleet.Treasury.Reading`: its symbol and decimals
  as the token reports them, the fleet's budget in it (`freeCapital`), what
  the reward ledger holds for the key holders in it (`backed`), and its
  current pay period: when it began (nil before any payment), its cap and
  what it has paid. Amounts are in the asset's atomic units, any uint256.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :asset, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    attribute :symbol, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :decimals, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: 255]

    for field <- [:free_capital, :backed, :pay_cap, :pay_spent] do
      attribute field, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    end

    attribute :pay_period_start, :utc_datetime_usec, public?: true
  end
end
