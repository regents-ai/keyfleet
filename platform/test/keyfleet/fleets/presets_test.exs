defmodule KeyFleet.Fleets.PresetsTest do
  use ExUnit.Case, async: true

  alias KeyFleet.Fleets.Presets

  # Pinned to contracts/test/KeyfleetPresets.t.sol: the site's ladder must round
  # exactly where the contract's does.
  test "the price ladders round up at every step exactly as the contract does" do
    assert Enum.map([1, 2, 3, 4, 5, 8, 9, 20], &Presets.fibonacci_level_price/1) ==
             [
               10_000_000,
               12_000_000,
               14_400_000,
               17_280_000,
               20_736_000,
               35_831_808,
               42_998_170,
               319_480_010
             ]

    assert Enum.map(0..4, &Presets.accelerant_price/1) ==
             [10_000_000, 10_500_000, 11_025_000, 11_576_250, 12_155_063]
  end

  # Token ids are contiguous, so levels and the next key follow from the count.
  test "a Fibonacci fleet's levels, next key and 10 USDC ladder follow from keys issued" do
    assert Enum.map([0, 2, 5, 10], fn minted ->
             progress = Presets.progress("fibonacci_syndicate", minted)
             {progress.completed_levels, progress.next_token_id, progress.next_price}
           end) == [
             {0, 1, 10_000_000},
             {1, 3, 12_000_000},
             {2, 6, 14_400_000},
             {3, 11, 17_280_000}
           ]

    assert %{max_supply: 46_365, completed_levels: 20, next_token_id: nil, next_price: nil} =
             Presets.progress("fibonacci_cascade", 46_365)
  end

  test "Classic holds 10 USDC and Accelerant climbs 5% a key from 10 USDC" do
    assert %{next_price: 10_000_000, max_supply: 144, completed_levels: nil} =
             Presets.progress("fleet_tech_classic", 143)

    assert %{next_price: 11_025_000, next_token_id: 3} =
             Presets.progress("fleet_tech_accelerant", 2)
  end
end
