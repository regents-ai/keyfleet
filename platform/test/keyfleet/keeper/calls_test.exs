defmodule Keyfleet.Keeper.CallsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Keyfleet.Keeper.Calls
  alias Keyfleet.Keeper.Calls.Call

  @fleet "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  @usdc "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  @zero "0x" <> String.duplicate("0", 40)
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935

  describe "the calls the keeper sends" do
    # Each expected value is `cast calldata <signature> <argument>`.
    test "encode exactly as cast does" do
      for {fun, arg, expected} <- [
            {:request_reveal, 1,
             "0x40261cdd0000000000000000000000000000000000000000000000000000000000000001"},
            {:send_protocol_share, nil, "0xcb097587"}
          ] do
        assert {:ok, %Call{fn: ^fun, target: @fleet, arg: ^arg} = call} =
                 Calls.new(fun, @fleet, arg)

        assert {:ok, data} = Calls.calldata(call)
        assert hex(data) == expected, inspect(fun)
      end
    end

    test "an unknown function is refused, however it is asked for" do
      for fun <- [
            :transfer,
            :approve,
            :fund_subscription_with_native,
            :release,
            :sync_launch,
            "send_protocol_share",
            nil
          ] do
        assert Calls.new(fun, @fleet, nil) == {:error, :unknown_function}

        assert Calls.calldata(%Call{fn: fun, target: @fleet, arg: nil}) ==
                 {:error, :unknown_function}
      end
    end

    test "the contract must be a nonzero lowercase address" do
      for target <- [
            @zero,
            String.upcase(@fleet) |> String.replace("0X", "0x"),
            "0x5FbDB2315678afecb367f032d93F642f64180aa3",
            String.slice(@fleet, 0..40),
            @fleet <> "00",
            String.trim_leading(@fleet, "0x"),
            nil,
            1
          ] do
        assert Calls.new(:send_protocol_share, target, nil) == {:error, :malformed_target}

        assert Calls.calldata(%Call{fn: :send_protocol_share, target: target, arg: nil}) ==
                 {:error, :malformed_target}
      end
    end

    test "the argument must have the function's one type" do
      for {fun, arg} <- [
            send_protocol_share: 0,
            send_protocol_share: 1,
            send_protocol_share: @usdc,
            request_reveal: nil,
            request_reveal: -1,
            request_reveal: @max_uint256 + 1,
            request_reveal: "1",
            request_reveal: 1.0,
            request_reveal: @usdc
          ] do
        assert Calls.new(fun, @fleet, arg) == {:error, :malformed_argument}, inspect({fun, arg})

        assert Calls.calldata(%Call{fn: fun, target: @fleet, arg: arg}) ==
                 {:error, :malformed_argument}
      end

      assert {:ok, _call} = Calls.new(:request_reveal, @fleet, @max_uint256)
    end

    # Nothing outside the module can hand it bytes to send, or ETH.
    test "no public function takes calldata or a value" do
      assert Calls.__info__(:functions) |> Enum.sort() ==
               [calldata: 1, decode: 2, functions: 0, new: 3, result: 4, view: 2]

      assert %Call{fn: :send_protocol_share, target: @fleet, arg: nil}
             |> Map.from_struct()
             |> Map.keys()
             |> Enum.sort() ==
               [:arg, :fn, :target]
    end
  end

  describe "views" do
    # Each expected value is `cast calldata <signature> <arguments>`.
    test "encode exactly as cast does" do
      for {name, args, expected} <- [
            {:reveal_seed, [7],
             "0x0413a0f00000000000000000000000000000000000000000000000000000000000000007"},
            {:reveal_requested_at, [7],
             "0xc3964cbe0000000000000000000000000000000000000000000000000000000000000007"},
            {:total_minted, [], "0xa2309ff8"},
            {:protocol_share_owed, [], "0xc490b9c7"},
            {:vrf_coordinator, [], "0x05f6a924"},
            {:vrf_subscription_id, [], "0x83109708"},
            {:get_subscription, [@max_uint256],
             "0xdc311dd3ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}
          ] do
        assert {:ok, data} = Calls.view(name, args)
        assert hex(data) == expected, inspect(name)
      end
    end

    test "the functions are the two the keeper may call" do
      assert Calls.functions() == [:request_reveal, :send_protocol_share]
    end

    test "only a view can be decoded" do
      for name <- [:owner, :request_reveal, :send_protocol_share] do
        assert Calls.decode(name, <<1::256>>) == :error, inspect(name)
      end
    end

    test "an unknown view or wrong arguments are refused" do
      assert Calls.view(:owner, []) == {:error, :unknown_view}
      assert Calls.view(:request_reveal, [1]) == {:error, :unknown_view}
      assert Calls.view(:launch_record, []) == {:error, :unknown_view}
      assert Calls.view(:total_minted, [1]) == {:error, :malformed_argument}
      assert Calls.view(:get_subscription, []) == {:error, :malformed_argument}
      assert Calls.view(:reveal_seed, [@usdc]) == {:error, :malformed_argument}
    end

    # Each encoded value is `cast abi-encode` of the view's return types.
    test "decode what they return" do
      seed = "0x" <> String.duplicate("ab", 32)

      for {name, encoded, expected} <- [
            {:reveal_seed, seed, seed},
            {:reveal_requested_at, word(1_700_000_000), 1_700_000_000},
            {:total_minted, word(42), 42},
            {:protocol_share_owed, word(1_250_000), 1_250_000},
            {:vrf_coordinator, "0x000000000000000000000000" <> String.trim_leading(@fleet, "0x"),
             @fleet},
            {:vrf_subscription_id, word(@max_uint256), @max_uint256}
          ] do
        assert Calls.decode(name, bytes(encoded)) == {:ok, expected}, inspect({name, encoded})
      end
    end

    test "decode a VRF subscription with its consumers" do
      # cast abi-encode "f(uint96,uint96,uint64,address,address[])" 5 20000000000000000 9 \
      #   <usdc> "[<fleet>,<usdc>]"
      encoded =
        "0x000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000470de4df8200000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

      assert Calls.decode(:get_subscription, bytes(encoded)) ==
               {:ok,
                %{
                  balance: 5,
                  native_balance: 20_000_000_000_000_000,
                  request_count: 9,
                  owner: @usdc,
                  consumers: [@fleet, @usdc]
                }}
    end

    test "anything but the exact encoding is refused" do
      for {name, data} <- [
            {:reveal_requested_at, <<1 <<< 64::256>>},
            {:total_minted, <<1::256, 2::256>>},
            {:total_minted, <<1::248>>},
            {:total_minted, <<>>},
            {:vrf_coordinator, <<1 <<< 160::256>>},
            {:protocol_share_owed, <<1::256, 0::8>>}
          ] do
        assert Calls.decode(name, data) == :error, inspect({name, data})
      end
    end
  end

  describe "a reveal's result" do
    # Each topic is `cast keccak <event signature>` of Keyfleet.sol's events.
    @requested "0x636f7c8c708e048e354abf12cce3c8388becccbc306c3aca98b59406c7e0a9d3"
    @refused "0x28313d2e4de81be16551ff59132121eb412ff359b73b349ff448835751346789"

    test "is what the fleet logged for that key" do
      assert Calls.result(:request_reveal, @fleet, 7, [
               log(@usdc, [@requested, word(7)]),
               log(@fleet, [@requested, word(7), word(99)])
             ]) == "reveal_requested"

      # A node may give addresses and topics in upper case.
      assert Calls.result(:request_reveal, @fleet, 7, [
               log(String.upcase(@fleet), [String.upcase(@refused), word(7)])
             ]) == "reveal_refused"
    end

    test "is nothing when the fleet logged neither for that key" do
      for logs <- [
            [],
            [log(@fleet, [@refused, word(8)])],
            [log(@usdc, [@refused, word(7)])],
            [log(@fleet, [word(1), word(7)])],
            [log(@fleet, [@refused])],
            [%{"address" => @fleet}]
          ] do
        assert Calls.result(:request_reveal, @fleet, 7, logs) == nil, inspect(logs)
      end

      assert Calls.result(:send_protocol_share, @fleet, nil, [log(@fleet, [@refused, word(7)])]) ==
               nil
    end
  end

  defp log(address, topics), do: %{"address" => address, "topics" => topics, "data" => "0x"}
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp word(value), do: hex(<<value::256>>)
end
