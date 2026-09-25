defmodule Keyfleet.TraitsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Traits

  # keccak256 of the fixture table, byte for byte, and so its file name in
  # test/support/fixtures/trait_tables.
  @hash "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"

  # Inputs of 0, 1, 2, ... wrapping at 256, across the lengths where a wrong
  # keccak goes wrong: one short of a word, and either side of and twice the
  # 136-byte block. Pinned from `cast keccak` of the same bytes.
  test "keccak256 agrees with the chain's at every length" do
    for {length, digest} <- [
          {31, "0x3e50547cf72e8583ee91462f9d99fe624f53282f78e1a5ec2347b1d0123d0d9b"},
          {135, "0xcbdfd9dee5faad3818d6b06f95a219fd290b0e1706f6a82e5a595b9ce9faca62"},
          {136, "0x7ce759f1ab7f9ce437719970c26b0a66ff11fe3e38e17df89cf5d29c7d7f807e"},
          {272, "0xfdf2ec49e749960d3c8521a0219af8d03e30e2b3bf19bd16150ee0eaf133d66e"}
        ] do
      bytes = :binary.list_to_bin(for i <- 0..(length - 1), do: rem(i, 256))
      assert Traits.keccak256(bytes) == digest, "#{length} bytes"
    end
  end

  test "the table named by the hash is read" do
    assert Traits.table!(@hash) == [
             %{
               name: "Hull",
               values: [{"Brass", 50}, {"Steel", 30}, {"Glass", 15}, {"Gold", 5}],
               total: 100
             },
             %{name: "Sky", values: [{"Dawn", 1}, {"Noon", 1}, {"Dusk", 1}], total: 3},
             %{name: "Mark", values: [{"Anchor", 0}, {"Star", 9}, {"Crown", 1}], total: 10}
           ]
  end

  @tag :tmp_dir
  test "a table missing or not hashing to its name is refused", %{tmp_dir: tmp_dir} do
    use_directory(tmp_dir)
    other = "0x" <> String.duplicate("0", 64)

    assert_raise File.Error, fn -> Traits.table!(other) end

    File.write!(Path.join(tmp_dir, other <> ".json"), ~s({"traits": []}))

    assert_raise RuntimeError, ~r/does not hash to #{other}/, fn -> Traits.table!(other) end
  end

  # The same seeds and weights as contracts/test/KeyfleetTraitDraw.t.sol, so
  # the site and the chain's own `abi.encode` and `keccak256` agree.
  test "golden seeds draw what the contracts' copy of the rule draws" do
    table = Traits.table!(@hash)

    for {name, picks} <- [
          {"golden-1", ["Steel", "Noon", "Star"]},
          {"golden-4", ["Brass", "Dawn", "Star"]},
          {"golden-5", ["Glass", "Dusk", "Star"]},
          {"golden-85", ["Gold", "Dusk", "Star"]},
          {"golden-105", ["Steel", "Dusk", "Crown"]}
        ] do
      assert Traits.draw(table, Traits.keccak256(name)) ==
               Enum.zip(["Hull", "Sky", "Mark"], picks),
             name
    end
  end

  # Over many seeds each value turns up in proportion to its weight, well
  # inside five standard deviations, and a value of weight 0 never does.
  test "values are drawn in proportion to their weights" do
    table = Traits.table!(@hash)
    draws = 10_000

    counts =
      1..draws
      |> Enum.flat_map(fn i ->
        Traits.draw(table, "0x" <> Base.encode16(:crypto.hash(:sha256, <<i::64>>), case: :lower))
      end)
      |> Enum.frequencies()

    for %{name: trait, values: values, total: total} <- table, {value, weight} <- values do
      p = weight / total
      expected = draws * p
      spread = 5 * :math.sqrt(draws * p * (1 - p))
      count = Map.get(counts, {trait, value}, 0)

      assert abs(count - expected) <= spread,
             "#{trait} #{value}: #{count} draws, expected #{expected} ± #{spread}"
    end

    refute Map.has_key?(counts, {"Mark", "Anchor"})
  end

  @tag :tmp_dir
  test "a trait whose weights add up to nothing or to 2^32 is refused", %{tmp_dir: tmp_dir} do
    use_directory(tmp_dir)

    for {weights, total} <- [{[0], 0}, {[4_294_967_295, 1], 4_294_967_296}] do
      values = Enum.map(weights, &%{"name" => "Brass #{&1}", "weight" => &1})
      bytes = Jason.encode!(%{"traits" => [%{"name" => "Hull", "values" => values}]})
      hash = Traits.keccak256(bytes)
      File.write!(Path.join(tmp_dir, hash <> ".json"), bytes)

      assert_raise RuntimeError, ~r/Hull weights add up to #{total},/, fn ->
        Traits.table!(hash)
      end
    end
  end

  defp use_directory(directory) do
    configured = Application.fetch_env!(:keyfleet, Traits)
    Application.put_env(:keyfleet, Traits, directory: directory)
    on_exit(fn -> Application.put_env(:keyfleet, Traits, configured) end)
  end
end
