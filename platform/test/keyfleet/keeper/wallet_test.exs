defmodule Keyfleet.Keeper.WalletTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Keyfleet.Keeper.{Calls, Rlp, Wallet}
  alias Keyfleet.Keeper.Calls.Call

  # Anvil's first public test account. Never a real key.
  @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @anvil_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @fleet "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  # cast mktx --private-key <anvil key> --chain 1 --nonce 0 --gas-limit 200000 \
  #   --priority-gas-price 1000000 --gas-price 2000000000 \
  #   0x5fbdb2315678afecb367f032d93f642f64180aa3 "requestReveal(uint256)" 1
  @reveal_raw "0x02f88e0180830f4240847735940083030d40945fbdb2315678afecb367f032d93f642f64180aa380a440261cdd0000000000000000000000000000000000000000000000000000000000000001c080a06010540e0453b5d173d6ce2998720d54f07fb5e5f433b07ded4d307ce142bb0fa059f9ac7456223d9e26aa2d0d309fc49f3148ac098e94fe4e93af05bae7d9f3bc"
  # cast keccak <the raw transaction above>
  @reveal_hash "0x5f7ad86ebad87af529d02fcfe4766a80bed76cbfb3723fad61aedd3af1029edc"

  # cast mktx --private-key <anvil key> --chain 1 --nonce 300 --gas-limit 260000 \
  #   --priority-gas-price 1250000 --gas-price 1500000000 \
  #   0x5fbdb2315678afecb367f032d93f642f64180aa3 "sendProtocolShare()"
  # (yParity 1 and a two-byte nonce)
  @share_raw "0x02f8700182012c831312d08459682f008303f7a0945fbdb2315678afecb367f032d93f642f64180aa38084cb097587c001a0396b6510d0f91ad3ee81eb8332d3e0b99e21e7f1632f2563bfb82c1e005ac106a0774277140a4fc382affef9b0848de7c43dab2e665ba58911534acbbb339e38cf"

  setup do
    {:ok, wallet} = Wallet.new(@anvil_key)
    %{wallet: wallet}
  end

  test "the anvil key sends from its known address", %{wallet: wallet} do
    assert wallet.address == @anvil_address
  end

  test "a signed call is byte for byte what cast makes", %{wallet: wallet} do
    {:ok, reveal} = Calls.new(:request_reveal, @fleet, 1)

    assert {:ok, {raw, hash}} =
             Wallet.sign(wallet, reveal, fees(nonce: 0, gas_limit: 200_000))

    assert hex(raw) == @reveal_raw
    assert hex(hash) == @reveal_hash

    {:ok, share} = Calls.new(:send_protocol_share, @fleet, nil)

    assert {:ok, {raw, _hash}} =
             Wallet.sign(
               wallet,
               share,
               fees(
                 nonce: 300,
                 gas_limit: 260_000,
                 max_priority_fee: 1_250_000,
                 max_fee: 1_500_000_000
               )
             )

    assert hex(raw) == @share_raw
  end

  test "every signature is low-s and recovers to the wallet", %{wallet: wallet} do
    {:ok, call} = Calls.new(:send_protocol_share, @fleet, nil)

    for nonce <- 0..63 do
      {:ok, {<<2, rlp::binary>>, _hash}} = Wallet.sign(wallet, call, fees(nonce: nonce))
      fields = decode(rlp)
      [chain_id, nonce_bytes, _tip, _max, _gas, to, value, data, [], y_parity, r, s] = fields

      assert {:binary.decode_unsigned(chain_id), :binary.decode_unsigned(nonce_bytes)} ==
               {1, nonce}

      assert {hex(to), value, Calls.calldata(call)} == {@fleet, <<>>, {:ok, data}}
      assert y_parity in [<<>>, <<1>>]
      assert :binary.decode_unsigned(s) <= div(@curve_order, 2)

      digest = ExKeccak.hash_256(<<2>> <> Rlp.encode(Enum.take(fields, 9)))
      assert signer(digest, pad(r) <> pad(s), :binary.decode_unsigned(y_parity)) == @anvil_address
    end
  end

  test "inspecting a wallet never shows its key", %{wallet: wallet} do
    "0x" <> key_hex = @anvil_key
    key = Base.decode16!(key_hex, case: :lower)

    for shown <- [inspect(wallet), inspect(wallet, limit: :infinity), inspect([wallet])] do
      assert shown =~ @anvil_address
      refute String.contains?(String.downcase(shown), key_hex)
      refute String.contains?(shown, inspect(key))
      refute String.contains?(shown, inspect(:binary.bin_to_list(key)))
    end
  end

  test "only a well-formed key in the curve's range makes a wallet" do
    for value <- [
          "0x" <> String.duplicate("0", 64),
          "0x" <> Integer.to_string(@curve_order, 16),
          "0x" <> Integer.to_string(@curve_order + 1, 16),
          "0x" <> String.duplicate("f", 64),
          "0x" <> String.duplicate("1", 63),
          "0x" <> String.duplicate("1", 65),
          "0x" <> String.duplicate("g", 64),
          String.duplicate("1", 64),
          "",
          nil
        ] do
      assert Wallet.new(value) == {:error, :malformed_key}
    end

    assert {:ok, _wallet} = Wallet.new("0x" <> String.duplicate("0", 63) <> "1")
    assert {:ok, _wallet} = Wallet.new(String.upcase(@anvil_key) |> String.replace("0X", "0x"))
  end

  test "a call Calls refuses is never signed", %{wallet: wallet} do
    for call <- [
          %Call{fn: :transfer, target: @fleet, arg: nil},
          %Call{fn: :request_reveal, target: @fleet, arg: -1},
          %Call{fn: :send_protocol_share, target: String.upcase(@fleet), arg: nil},
          %Call{fn: :send_protocol_share, target: @fleet, arg: 1},
          %Call{fn: :sweep, target: @fleet, arg: @fleet}
        ] do
      assert {:error, _reason} = Wallet.sign(wallet, call, fees(nonce: 0))
    end
  end

  test "fees, nonce and gas outside what a transaction can carry are refused",
       %{wallet: wallet} do
    {:ok, reveal} = Calls.new(:request_reveal, @fleet, 1)

    for {overrides, reason} <- [
          {[max_priority_fee: 2_000_000_001], :priority_fee_above_max_fee},
          {[nonce: (1 <<< 64) - 1], :nonce_too_high},
          {[nonce: 1 <<< 64], :nonce_too_high},
          {[chain_id: -1], :malformed_transaction},
          {[chain_id: 0], :malformed_transaction},
          {[nonce: -1], :malformed_transaction},
          {[max_priority_fee: -1], :malformed_transaction},
          {[max_fee: -1], :malformed_transaction},
          {[gas_limit: -1], :malformed_transaction},
          {[max_fee: 1 <<< 256], :malformed_transaction},
          {[max_fee: 2.0e9], :malformed_transaction},
          {[nonce: "1"], :malformed_transaction},
          {[gas_limit: 0], :gas_limit_out_of_range},
          {[gas_limit: 30_000_001], :gas_limit_out_of_range}
        ] do
      assert Wallet.sign(wallet, reveal, fees([nonce: 0] ++ overrides)) == {:error, reason},
             inspect(overrides)
    end

    for overrides <- [
          [nonce: (1 <<< 64) - 2],
          [gas_limit: 1],
          [gas_limit: 30_000_000],
          [max_priority_fee: 2_000_000_000]
        ] do
      assert {:ok, _signed} = Wallet.sign(wallet, reveal, fees([nonce: 0] ++ overrides))
    end
  end

  describe "Rlp" do
    test "encodes the reference cases" do
      for {item, expected} <- [
            {"", "80"},
            {0, "80"},
            {<<0>>, "00"},
            {15, "0f"},
            {127, "7f"},
            {128, "8180"},
            {1024, "820400"},
            {"dog", "83646f67"},
            {[], "c0"},
            {["cat", "dog"], "c88363617483646f67"},
            {[[], [[]], [[], [[]]]], "c7c0c1c0c3c0c1c0"},
            {String.duplicate("a", 55), "b7" <> String.duplicate("61", 55)},
            {String.duplicate("a", 56), "b838" <> String.duplicate("61", 56)},
            {List.duplicate("abc", 14), "f838" <> String.duplicate("83616263", 14)}
          ] do
        assert Base.encode16(Rlp.encode(item), case: :lower) == expected, inspect(item)
      end
    end
  end

  defp fees(overrides) do
    Map.merge(
      %{
        chain_id: 1,
        max_priority_fee: 1_000_000,
        max_fee: 2_000_000_000,
        gas_limit: 200_000
      },
      Map.new(overrides)
    )
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp signer(digest, signature, recovery_id) do
    {:ok, <<4, public_key::binary-size(64)>>} =
      ExSecp256k1.recover_compact(digest, signature, recovery_id)

    <<_::binary-size(12), address::binary>> = ExKeccak.hash_256(public_key)
    hex(address)
  end

  defp pad(bytes), do: <<0::size(8 * (32 - byte_size(bytes)))>> <> bytes

  # Just enough of RLP decoding to read back a signed transaction; integers
  # come back as their minimal big-endian bytes.
  defp decode(bytes) do
    {item, <<>>} = item(bytes)
    item
  end

  defp item(<<byte, rest::binary>>) when byte < 0x80, do: {<<byte>>, rest}

  defp item(<<prefix, rest::binary>>) when prefix <= 0xB7,
    do: split(rest, prefix - 0x80)

  defp item(<<prefix, rest::binary>>) when prefix < 0xC0 do
    <<length::size(8 * (prefix - 0xB7)), rest::binary>> = rest
    split(rest, length)
  end

  defp item(<<prefix, rest::binary>>) when prefix <= 0xF7, do: list(rest, prefix - 0xC0)

  defp item(<<prefix, rest::binary>>) do
    <<length::size(8 * (prefix - 0xF7)), rest::binary>> = rest
    list(rest, length)
  end

  defp split(bytes, length) do
    <<item::binary-size(length), rest::binary>> = bytes
    {item, rest}
  end

  defp list(bytes, length) do
    {payload, rest} = split(bytes, length)
    {items(payload, []), rest}
  end

  defp items(<<>>, items), do: Enum.reverse(items)

  defp items(payload, items) do
    {item, rest} = item(payload)
    items(rest, [item | items])
  end
end
