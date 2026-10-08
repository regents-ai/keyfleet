defmodule Keyfleet.DecksTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Decks

  @table "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:keyfleet, Decks)
    Application.put_env(:keyfleet, Decks, directory: tmp_dir)
    on_exit(fn -> Application.put_env(:keyfleet, Decks, configured) end)
  end

  # A deck's hash goes into its fleet's creation for good, so the site must
  # read back exactly the deck that was made, in the same card order.
  @tag :tmp_dir
  test "a new deck reads back under its hash, card for card", %{tmp_dir: tmp_dir} do
    {hash, bytes} = Decks.new("CLASSIC #1", @table, 5)
    File.write!(Path.join(tmp_dir, hash <> ".json"), bytes)

    assert %{fleet: "CLASSIC #1", table: @table, cards: cards} = Decks.deck!(hash)
    assert cards == bytes |> Jason.decode!() |> Map.fetch!("cards") |> List.to_tuple()
    assert tuple_size(cards) == 5
    assert cards |> Tuple.to_list() |> Enum.uniq() |> length() == 5
  end

  # A deck changed after its fleet was created must never be dealt from.
  @tag :tmp_dir
  test "a deck not hashing to its name is refused", %{tmp_dir: tmp_dir} do
    {hash, bytes} = Decks.new("CLASSIC #1", @table, 5)
    File.write!(Path.join(tmp_dir, hash <> ".json"), String.replace(bytes, "CLASSIC", "CASCADE"))

    assert_raise RuntimeError, ~r/does not hash to #{hash}/, fn -> Decks.deck!(hash) end
  end
end
