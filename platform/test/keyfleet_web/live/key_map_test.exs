defmodule KeyfleetWeb.KeyMapTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.KeyMap

  # Key `id` is bit `(id - 1) rem 8` of byte `(id - 1) div 8`, least
  # significant first, over `ceil(max_supply / 8)` bytes.
  test "a bitset sets each key's bit in order, least significant first" do
    assert Base.decode64!(KeyMap.bitset(16, [1, 12])) == <<0b00000001, 0b00001000>>
    # The browser's map reads this one back in assets/test/key_map_state.test.ts.
    assert KeyMap.bitset(10, [2, 10]) == "AgI="
    assert Base.decode64!(KeyMap.bitset(1_024, [])) == <<0::size(128 * 8)>>
  end

  test "a bitset takes 5,796 bytes at the largest fleet's size" do
    bitset = KeyMap.bitset(46_365, 1..46_365)

    assert byte_size(bitset) == 7_728
    assert Base.decode64!(bitset) == :binary.copy(<<255>>, 5_795) <> <<0b00011111>>
  end

  test "every key sold and the next one can be chosen, and nothing past the fleet's size" do
    progress = %{total_minted: 150, max_supply: 46_365}
    assert KeyMap.choosable?(progress, 1)
    assert KeyMap.choosable?(progress, 151)
    refute KeyMap.choosable?(progress, 0)
    refute KeyMap.choosable?(progress, 152)
    refute KeyMap.choosable?(progress, "7")

    sold_out = %{total_minted: 1_024, max_supply: 1_024}
    assert KeyMap.choosable?(sold_out, 1_024)
    refute KeyMap.choosable?(sold_out, 1_025)
  end

  test "the map goes to each level with a key sold or on sale, and the level after" do
    assert KeyMap.levels(%{levels: 20, completed_levels: 0}) == [1, 2]
    assert KeyMap.levels(%{levels: 20, completed_levels: 8}) == Enum.to_list(1..10)
    assert KeyMap.levels(%{levels: 20, completed_levels: 19}) == Enum.to_list(1..20)
    assert KeyMap.levels(%{levels: 20, completed_levels: 20}) == Enum.to_list(1..20)
    assert KeyMap.levels(%{levels: nil, completed_levels: nil}) == []
  end
end
