defmodule KeyFleet.Keeper.CallsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias KeyFleet.Keeper.Calls
  alias KeyFleet.Keeper.Calls.Call

  @fleet "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @zero "0x" <> String.duplicate("0", 40)
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935

  describe "the calls the keeper sends" do
    # Each expected value is `cast calldata <signature> <argument>`.
    test "encode exactly as cast does" do
      for {fun, arg, expected} <- [
            {:request_reveal, 1,
             "0x40261cdd0000000000000000000000000000000000000000000000000000000000000001"},
            {:release, nil, "0x86d1a69f"},
            {:collect, 1_234_567,
             "0xce3f865f000000000000000000000000000000000000000000000000000000000012d687"},
            {:sweep, @usdc,
             "0x01681a62000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:recognize_surplus_revenue, @usdc,
             "0xeac37a82000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:recognize_surplus, @usdc,
             "0xaef04030000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:send_protocol_share, nil, "0xcb097587"},
            {:sync_launch, nil, "0x8e9e57df"},
            {:migrate, @usdc,
             "0xce5494bb000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"}
          ] do
        assert {:ok, %Call{fn: ^fun, target: @fleet, arg: ^arg} = call} =
                 Calls.new(fun, @fleet, arg)

        assert {:ok, data} = Calls.calldata(call)
        assert hex(data) == expected, inspect(fun)
      end
    end

    test "an unknown function is refused, however it is asked for" do
      for fun <- [:transfer, :approve, :fund_subscription_with_native, "release", nil] do
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
        assert Calls.new(:release, target, nil) == {:error, :malformed_target}

        assert Calls.calldata(%Call{fn: :release, target: target, arg: nil}) ==
                 {:error, :malformed_target}
      end
    end

    test "the argument must have the function's one type" do
      for {fun, arg} <- [
            release: 0,
            release: @usdc,
            send_protocol_share: 1,
            sync_launch: @fleet,
            migrate: nil,
            migrate: 1,
            request_reveal: nil,
            request_reveal: -1,
            request_reveal: @max_uint256 + 1,
            request_reveal: "1",
            request_reveal: 1.0,
            collect: @usdc,
            sweep: nil,
            sweep: 1,
            sweep: String.upcase(@usdc),
            recognize_surplus: [@usdc],
            recognize_surplus_revenue: "0x1234"
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

      assert %Call{fn: :release, target: @fleet, arg: nil}
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
            {:surplus, [@usdc],
             "0x176d698e000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:protocol_share_owed, [], "0xc490b9c7"},
            {:launch_state, [], "0x2fcd0f25"},
            {:launch_record, [], "0xff1ac947"},
            {:launch_distribution, [], "0x7827f7c7"},
            {:factory, [], "0x2dd31000"},
            {:asset_registry, [], "0x514ef8dd"},
            {:vrf_coordinator, [], "0x05f6a924"},
            {:vrf_subscription_id, [], "0x83109708"},
            {:is_token_allowed, [@fleet, @usdc],
             "0xd987a9f90000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:get_subscription, [@max_uint256],
             "0xdc311dd3ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"},
            {:strategy, [], "0xa8c62e76"},
            {:lp_locker, [], "0x03fc2013"},
            {:lifecycle, [], "0xac0cc868"},
            {:total_released, [], "0xe33b7de3"},
            {:vesting_start, [], "0x254800d4"},
            {:treasury, [], "0x61d027b3"},
            {:subject, [], "0x0a59a98c"},
            {:usdc, [], "0x3e413bee"},
            {:regent, [], "0x35cd696e"},
            {:protected_balance, [@usdc],
             "0x3dc1a23b000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
            {:balance_of, [@fleet],
             "0x70a082310000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3"}
          ] do
        assert {:ok, data} = Calls.view(name, args)
        assert hex(data) == expected, inspect(name)
      end
    end

    test "the functions are the nine the keeper may call" do
      assert Calls.functions() == [
               :collect,
               :migrate,
               :recognize_surplus,
               :recognize_surplus_revenue,
               :release,
               :request_reveal,
               :send_protocol_share,
               :sweep,
               :sync_launch
             ]
    end

    test "only a view, collect or syncLaunch can be decoded" do
      for name <- [:owner, :request_reveal, :sweep, :send_protocol_share] do
        assert Calls.decode(name, <<1::256>>) == :error, inspect(name)
      end
    end

    test "an unknown view or wrong arguments are refused" do
      assert Calls.view(:owner, []) == {:error, :unknown_view}
      assert Calls.view(:request_reveal, [1]) == {:error, :unknown_view}
      assert Calls.view(:total_minted, [1]) == {:error, :malformed_argument}
      assert Calls.view(:balance_of, []) == {:error, :malformed_argument}
      assert Calls.view(:balance_of, [1]) == {:error, :malformed_argument}
      assert Calls.view(:reveal_seed, [@usdc]) == {:error, :malformed_argument}
    end

    # Each encoded value is `cast abi-encode` of the view's return types.
    test "decode what they return" do
      seed = "0x" <> String.duplicate("ab", 32)

      for {name, encoded, expected} <- [
            {:reveal_seed, seed, seed},
            {:reveal_requested_at, word(1_700_000_000), 1_700_000_000},
            {:total_minted, word(42), 42},
            {:is_token_allowed, word(1), true},
            {:is_token_allowed, word(0), false},
            {:treasury, "0x000000000000000000000000" <> String.trim_leading(@fleet, "0x"),
             @fleet},
            {:launch_state, word(0), :not_created},
            {:launch_state, word(1), :auction_created},
            {:launch_state, word(2), :graduated},
            {:launch_state, word(3), :economically_failed},
            {:lifecycle, word(0), :pending},
            {:lifecycle, word(1), :graduated},
            {:lifecycle, word(2), :failed},
            {:collect, word(12) <> String.duplicate("0", 64), {12, 0}},
            {:sync_launch, word(1), :auction_created},
            {:sync_launch, word(2), :graduated},
            {:sync_launch, word(3), :economically_failed}
          ] do
        assert Calls.decode(name, bytes(encoded)) == {:ok, expected}, inspect({name, encoded})
      end
    end

    test "decode a VRF subscription with its consumers" do
      # cast abi-encode "f(uint96,uint96,uint64,address,address[])" 5 20000000000000000 9 \
      #   <usdc> "[<fleet>,<usdc>]"
      encoded =
        "0x000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000470de4df8200000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"

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

    test "decode a fleet's launch record" do
      # cast abi-encode "f((uint256,uint256,address,uint64,address,address,address,address,
      #   bytes32,bytes32,uint256))" \
      #   "(1,2,<usdc>,3,0x11..11,0x22..22,0x33..33,0x44..44,0xabab..ab,0xcdcd..cd,99)"
      encoded =
        "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000000000000000000000000000000000000000000030000000000000000000000001111111111111111111111111111111111111111000000000000000000000000222222222222222222222222222222222222222200000000000000000000000033333333333333333333333333333333333333330000000000000000000000004444444444444444444444444444444444444444ababababababababababababababababababababababababababababababababcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd0000000000000000000000000000000000000000000000000000000000000063"

      assert Calls.decode(:launch_record, bytes(encoded)) ==
               {:ok,
                %{
                  launch_id: 1,
                  proposal_id: 2,
                  subject: @usdc,
                  created_at_block: 3,
                  auction: address("1"),
                  escrow: address("2"),
                  splitter: address("3"),
                  receiver: address("4"),
                  envelope_hash: "0x" <> String.duplicate("ab", 32),
                  pool_id: "0x" <> String.duplicate("cd", 32),
                  lp_token_id: 99
                }}
    end

    test "decode a launch's distribution, naming its lifecycle" do
      # cast abi-encode "f((uint8,uint64,uint64,uint64,uint64,uint128,uint128,uint128,uint128,
      #   uint160,uint256,address,address,address,address,address,bytes32,uint256))" \
      #   "(2,10,20,30,40,50,60,70,80,90,1,<usdc>,0x22..22,<fleet>,0x33..33,0x44..44,0xefef..ef,77)"
      encoded =
        "0x0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000460000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000005a0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000022222222222222222222222222222222222222220000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa300000000000000000000000033333333333333333333333333333333333333330000000000000000000000004444444444444444444444444444444444444444efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef000000000000000000000000000000000000000000000000000000000000004d"

      assert {:ok, distribution} = Calls.decode(:launch_distribution, bytes(encoded))

      assert distribution == %{
               lifecycle: :graduated,
               start_block: 10,
               end_block: 20,
               claim_block: 30,
               migration_block: 40,
               required_regent_raised: 50,
               reserve: 60,
               lp_regent_used: 70,
               lp_subject_used: 80,
               final_sqrt_price_x96: 90,
               launch_id: 1,
               subject: @usdc,
               escrow: address("2"),
               treasury: @fleet,
               splitter: address("3"),
               receiver: address("4"),
               pool_id: "0x" <> String.duplicate("ef", 32),
               lp_token_id: 77
             }

      for {lifecycle, name} <- [{0, :none}, {1, :active}, {3, :failed}] do
        other = bytes(word(lifecycle)) <> binary_part(bytes(encoded), 32, 17 * 32)
        assert {:ok, %{lifecycle: ^name}} = Calls.decode(:launch_distribution, other)
      end

      unknown = bytes(word(4)) <> binary_part(bytes(encoded), 32, 17 * 32)
      assert Calls.decode(:launch_distribution, unknown) == :error
    end

    test "anything but the exact encoding is refused" do
      for {name, data} <- [
            {:launch_state, <<4::256>>},
            {:lifecycle, <<3::256>>},
            {:is_token_allowed, <<2::256>>},
            {:reveal_requested_at, <<1 <<< 64::256>>},
            {:total_minted, <<1::256, 2::256>>},
            {:total_minted, <<1::248>>},
            {:total_minted, <<>>},
            {:treasury, <<1 <<< 160::256>>},
            {:collect, <<1::256>>},
            {:sync_launch, <<4::256>>},
            {:sync_launch, <<1::256, 2::256>>}
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

      assert Calls.result(:release, @fleet, nil, [log(@fleet, [@refused, word(7)])]) == nil
    end
  end

  defp log(address, topics), do: %{"address" => address, "topics" => topics, "data" => "0x"}
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp word(value), do: hex(<<value::256>>)
  defp address(digit), do: "0x" <> String.duplicate(digit, 40)
end
