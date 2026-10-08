defmodule KeyfleetWeb.KeyMapTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.KeyMap

  # Key `id` is bit `(id - 1) rem 8` of byte `(id - 1) div 8`, least
  # significant first, over as many bytes as the highest key needs.
  test "a bitset sets each key's bit in order, least significant first" do
    assert Base.decode64!(KeyMap.bitset([1, 12])) == <<0b00000001, 0b00001000>>
    # The browser's map reads this one back in assets/test/key_map_state.test.ts.
    assert KeyMap.bitset([2, 10]) == "AgI="
    assert KeyMap.bitset([]) == ""
  end

  test "a bitset reaches only as far as the highest key marked" do
    assert byte_size(Base.decode64!(KeyMap.bitset([7]))) == 1
    assert byte_size(Base.decode64!(KeyMap.bitset([8]))) == 1
    assert byte_size(Base.decode64!(KeyMap.bitset([9]))) == 2

    bitset = KeyMap.bitset(1..46_366)
    assert Base.decode64!(bitset) == :binary.copy(<<255>>, 5_795) <> <<0b00111111>>
  end

  test "every key minted and the next one can be chosen, and nothing past a limited fleet's size" do
    progress = %{total_minted: 150, next_token_id: 151}
    assert KeyMap.choosable?(progress, 1)
    assert KeyMap.choosable?(progress, 151)
    refute KeyMap.choosable?(progress, 0)
    refute KeyMap.choosable?(progress, 152)
    refute KeyMap.choosable?(progress, "7")

    sold_out = %{total_minted: 1_024, next_token_id: nil}
    assert KeyMap.choosable?(sold_out, 1_024)
    refute KeyMap.choosable?(sold_out, 1_025)

    # The Regents Club sells none: the key after the last given is not offered.
    club = %{total_minted: 80, next_token_id: nil}
    assert KeyMap.choosable?(club, 80)
    refute KeyMap.choosable?(club, 81)
  end

  test "the map goes to each level with a key sold and the level on sale" do
    assert KeyMap.levels(%{completed_levels: 0}) == [1]
    assert KeyMap.levels(%{completed_levels: 8}) == Enum.to_list(1..9)
    assert KeyMap.levels(%{completed_levels: 24}) == Enum.to_list(1..25)
    assert KeyMap.levels(%{completed_levels: nil}) == []
  end
end
