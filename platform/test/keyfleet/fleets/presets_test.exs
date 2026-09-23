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

  # Levels end at keys 2, 5, 10, 18, … and 46,365.
  test "a Fibonacci key writes its own level, and a later level only once every key of it is sold" do
    assert Enum.map([2, 4, 5, 9, 10], &Presets.writable_levels(1, &1)) ==
             [[1], [1], [1, 2], [1, 2], [1, 2, 3]]

    assert Enum.map([3, 5, 10, 18], &Presets.writable_levels(3, &1)) ==
             [[2], [2], [2, 3], [2, 3, 4]]

    # A key whose own level is not yet complete still writes it, and never an earlier one.
    assert Presets.writable_levels(6, 6) == [3]
    assert Presets.writable_levels(10, 46_365) == Enum.to_list(3..20)
    assert Presets.writable_levels(46_365, 46_365) == [20]

    assert Enum.map([0, 1, 46_365, 46_366], &Presets.fibonacci_token?/1) == [
             false,
             true,
             true,
             false
           ]
  end

  # Pinned to contracts/test/KeyfleetPresets.t.sol.
  test "a wallet may hold one key of each of the first seven levels, then a tenth of a level" do
    assert Enum.map(1..7, &Presets.fibonacci_holding_limit/1) == List.duplicate(1, 7)

    assert Enum.map([8, 9, 10, 20], &Presets.fibonacci_holding_limit/1) == [5, 8, 14, 1_771]
  end

  # Someone holding keys of several levels writes what each key writes.
  test "keys of several levels write each held level, and later levels from the lowest" do
    assert Presets.levels_writable_by([], 46_365) == []
    assert Presets.levels_writable_by([3, 1, 3], 10) == [1, 2, 3]
    assert Presets.levels_writable_by([4, 2], 5) == [2, 4]
    assert Presets.levels_writable_by([4, 2], 18) == [2, 3, 4]
    assert Presets.levels_writable_by([20], 46_365) == [20]
  end

  # A level opens with its first key: 1, 3, 6, 11, 19, … and 28,655.
  test "a Fibonacci level runs from its first key to its last, and is open once its first sells" do
    assert Enum.map(
             [0, 1, 2, 3, 5, 6, 10, 11, 230, 231, 28_654, 28_655, 46_365],
             &Presets.active_levels/1
           ) ==
             [0, 1, 1, 2, 2, 3, 3, 4, 9, 10, 19, 20, 20]

    assert {starts, ends} = Presets.fibonacci_level_bounds()
    assert Enum.map(starts, &Presets.fibonacci_level_of/1) == Enum.to_list(1..20)
    assert Enum.map(ends, &Presets.fibonacci_level_of/1) == Enum.to_list(1..20)

    assert Enum.map(Enum.drop(starts, 1), &Presets.fibonacci_level_of(&1 - 1)) ==
             Enum.to_list(1..19)

    assert starts ==
             [
               1,
               3,
               6,
               11,
               19,
               32,
               53,
               87,
               142,
               231,
               375,
               608,
               985,
               1_595,
               2_582,
               4_179,
               6_763,
               10_944,
               17_709,
               28_655
             ]
  end

  test "only the two Fibonacci fleets have levels" do
    assert Enum.filter(KeyFleet.Fleets.catalog_ids(), &Presets.levelled?/1) ==
             ["fibonacci_syndicate", "fibonacci_cascade"]
  end

  test "Classic holds 10 USDC and Accelerant climbs 5% a key from 10 USDC" do
    assert %{next_price: 10_000_000, max_supply: 144, completed_levels: nil} =
             Presets.progress("fleet_tech_classic", 143)

    assert %{next_price: 11_025_000, next_token_id: 3} =
             Presets.progress("fleet_tech_accelerant", 2)
  end
end
