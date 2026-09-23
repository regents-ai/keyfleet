defmodule KeyFleet.TreasuryReaderTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain.{StubClient, TreasuryReader}
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.ProposalHelpers
  alias KeyFleet.Proposals
  alias KeyFleet.Repo
  alias KeyFleet.Treasury

  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @rewards "0x" <> String.duplicate("8", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @other "0x" <> String.duplicate("5", 40)
  @deposited "0x" <> String.duplicate("3", 40)
  @named "0x" <> String.duplicate("4", 40)
  @max_uint256 2 ** 256 - 1
  @head_hash "0x" <> String.duplicate("f", 64)
  @period_start 1_700_000_000

  # Pinned from `cast sig` of each view function, and against the contracts
  # in contracts/test/KeyfleetVotesTopics.t.sol.
  @reward_assets <<0x88, 0x0E, 0xC0, 0x4E>>
  @free_capital <<0x2B, 0x84, 0x30, 0x8E>>
  @pay_period <<0xE6, 0xEC, 0x9E, 0x56>>
  @backed <<0x59, 0x5B, 0x7F, 0x21>>
  @cascade_reserve <<0xFC, 0x4E, 0x89, 0x64>>
  @protocol_share_owed <<0xC4, 0x90, 0xB9, 0xC7>>
  @launch_settled <<0x06, 0xE9, 0x3D, 0xAE>>
  @decimals <<0x31, 0x3C, 0xE5, 0x67>>
  @symbol <<0x95, 0xD8, 0x9B, 0x41>>

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    fleet =
      @fleet
      |> Fleets.get_fleet!()
      |> Fleets.record_deployment!(
        %{
          chain_id: 8_453,
          contract_address: @contract,
          rewards_address: @rewards,
          votes_address: "0x" <> String.duplicate("9", 40),
          usdc_address: @usdc,
          deployed_block: 1,
          trait_table_hash: "0x" <> String.duplicate("a", 64)
        },
        actor: %System{}
      )

    %{fleet: fleet}
  end

  # Every figure is read at the head's block and kept together, for USDC,
  # the reward ledger's assets and every other asset the budget has held,
  # and the proposal pages are told.
  test "a reading keeps every balance from the one block it was read at", %{fleet: fleet} do
    Phoenix.PubSub.subscribe(KeyFleet.PubSub, Proposals.topic(@fleet))
    ProposalHelpers.budget_receipt!(@fleet, asset: @deposited)
    ProposalHelpers.budget_receipt!(@fleet, asset: @deposited, kind: :surplus)
    ProposalHelpers.income_split!(@fleet, asset: @other)
    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, asset: @named)
    StubClient.put_chain(head(40), [], calls: answers(chain()))

    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:balances_changed, @fleet}
    refute_received {:proposals_changed, _fleet}

    requests = StubClient.call_requests()
    assert length(requests) == 24
    assert Enum.all?(requests, fn {_to, _data, block_hash} -> block_hash == @head_hash end)

    reading = Treasury.get_reading!(@fleet)

    assert %{block_number: 40, block_hash: @head_hash, launch_settled: true} = reading
    assert Enum.map(reading.assets, & &1.asset) == [@usdc, @other, @deposited, @named]
    [usdc, other, deposited, named] = reading.assets

    assert DateTime.compare(reading.block_time, head(40).timestamp) == :eq
    assert Decimal.equal?(reading.cascade_reserve, 700)
    assert Decimal.equal?(reading.protocol_share_owed, 800)

    assert %{asset: @usdc, pay_period_start: nil} = usdc
    assert %{free_capital: 100_000_000, backed: 30_000_000, pay_cap: 0, pay_spent: 0} = usdc

    assert DateTime.compare(other.pay_period_start, DateTime.from_unix!(@period_start)) == :eq
    assert %{free_capital: 5_000, pay_cap: 1_000, pay_spent: 400, backed: 60} = other

    # Every digit of the largest amount the contract can hold is kept.
    assert deposited.free_capital == @max_uint256
    assert named.free_capital == 0

    # Each token's symbol and decimals, or nothing for one it does not answer.
    assert details() == %{
             @usdc => {"USDC", 6},
             @other => {"WETH", 18},
             @deposited => {"DEP", nil},
             @named => {nil, nil}
           }
  end

  # An asset's symbol and decimals are read once, and never again.
  test "an asset's symbol and decimals are read once", %{fleet: fleet} do
    StubClient.put_chain(head(40), [], calls: answers(chain()))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    renamed = Map.put(chain(), {@usdc, @symbol}, {:ok, text("USDX")})
    StubClient.put_chain(head(41), [], calls: answers(renamed))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    refute Enum.any?(StubClient.call_requests(), fn {_to, data, _hash} ->
             data in [@symbol, @decimals]
           end)

    assert details()[@usdc] == {"USDC", 6}
  end

  # A figure that cannot be read, or reads as something else, keeps nothing,
  # and a token that cannot be reached is asked again, not taken as silent.
  test "a reading that fails in any part keeps nothing", %{fleet: fleet} do
    for {key, answer, reason} <- [
          {{@other, @symbol}, {:error, :chain_unavailable}, {@other, :chain_unavailable}},
          {{@rewards, @backed <> word(@other)}, {:error, :chain_unavailable},
           {@rewards, :chain_unavailable}},
          {{@contract, @launch_settled}, {:ok, <<2::256>>}, {@contract, :unreadable_answer}}
        ] do
      StubClient.put_chain(head(40), [], calls: answers(Map.put(chain(), key, answer)))

      assert TreasuryReader.read(fleet, StubClient) == {:error, reason}
      assert Treasury.get_reading!(@fleet) == nil

      # USDC's were kept, and the unreachable token's were not.
      if reason == {@other, :chain_unavailable},
        do: assert(Map.keys(details()) == [@usdc])
    end

    refute_received {:balances_changed, _fleet}
  end

  # A reading that fails leaves the one kept as it was.
  test "a failed reading leaves the previous one untouched", %{fleet: fleet} do
    StubClient.put_chain(head(40), [], calls: answers(chain()))
    assert {:ok, kept} = TreasuryReader.read(fleet, StubClient)

    failing =
      chain()
      |> Map.put({@contract, @cascade_reserve}, {:ok, <<1::256>>})
      |> Map.put({@contract, @protocol_share_owed}, {:error, :chain_unavailable})

    StubClient.put_chain(head(41), [], calls: answers(failing))

    assert TreasuryReader.read(fleet, StubClient) ==
             {:error, {@contract, :chain_unavailable}}

    reading = Treasury.get_reading!(@fleet)
    assert reading.id == kept.id
    assert {reading.block_number, reading.block_hash} == {40, @head_hash}
    assert Decimal.equal?(reading.cascade_reserve, 700)
    assert reading.assets == kept.assets
  end

  # A reading from an earlier block, or the same one, never replaces the one
  # kept, and is not announced.
  test "an earlier reading does not replace a later one", %{fleet: fleet} do
    Phoenix.PubSub.subscribe(KeyFleet.PubSub, Proposals.topic(@fleet))
    StubClient.put_chain(head(40), [], calls: answers(chain()))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:balances_changed, @fleet}

    earlier = Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<1::256>>})

    for number <- [39, 40] do
      StubClient.put_chain(head(number), [], calls: answers(earlier))
      assert {:ok, _skipped} = TreasuryReader.read(fleet, StubClient)
      refute_received {:balances_changed, _fleet}
    end

    reading = Treasury.get_reading!(@fleet)
    assert reading.block_number == 40
    assert Decimal.equal?(reading.cascade_reserve, 700)

    later = Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<2::256>>})
    StubClient.put_chain(head(41), [], calls: answers(later))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:balances_changed, @fleet}

    reading = Treasury.get_reading!(@fleet)
    assert reading.block_number == 41
    assert Decimal.equal?(reading.cascade_reserve, 2)
  end

  defp details do
    @fleet
    |> Treasury.asset_details!()
    |> Map.new(&{&1.asset, {&1.symbol, &1.decimals}})
  end

  defp chain do
    %{
      {@rewards, @reward_assets} => {:ok, <<32::256, 2::256>> <> word(@usdc) <> word(@other)},
      {@deposited, @symbol} => {:ok, text("DEP")},
      {@deposited, @decimals} => {:error, :reverted},
      {@contract, @free_capital <> word(@deposited)} => {:ok, <<@max_uint256::256>>},
      {@contract, @pay_period <> word(@deposited)} => {:ok, <<0::256, 0::256, 0::256>>},
      {@rewards, @backed <> word(@deposited)} => {:ok, <<0::256>>},
      {@named, @symbol} => {:error, :reverted},
      {@named, @decimals} => {:ok, <<256::256>>},
      {@contract, @free_capital <> word(@named)} => {:ok, <<0::256>>},
      {@contract, @pay_period <> word(@named)} => {:ok, <<0::256, 0::256, 0::256>>},
      {@rewards, @backed <> word(@named)} => {:ok, <<0::256>>},
      {@usdc, @symbol} => {:ok, text("USDC")},
      {@usdc, @decimals} => {:ok, <<6::256>>},
      {@contract, @free_capital <> word(@usdc)} => {:ok, <<100_000_000::256>>},
      {@contract, @pay_period <> word(@usdc)} => {:ok, <<0::256, 0::256, 0::256>>},
      {@rewards, @backed <> word(@usdc)} => {:ok, <<30_000_000::256>>},
      {@other, @symbol} => {:ok, text("WETH")},
      {@other, @decimals} => {:ok, <<18::256>>},
      {@contract, @free_capital <> word(@other)} => {:ok, <<5_000::256>>},
      {@contract, @pay_period <> word(@other)} =>
        {:ok, <<@period_start::256, 1_000::256, 400::256>>},
      {@rewards, @backed <> word(@other)} => {:ok, <<60::256>>},
      {@contract, @cascade_reserve} => {:ok, <<700::256>>},
      {@contract, @protocol_share_owed} => {:ok, <<800::256>>},
      {@contract, @launch_settled} => {:ok, <<1::256>>}
    }
  end

  defp answers(chain) do
    fn to, data, _block_hash -> Map.get(chain, {to, data}, {:error, :no_answer}) end
  end

  defp head(number),
    do: %{
      number: number,
      hash: @head_hash,
      timestamp: DateTime.from_unix!(1_700_000_000 + number)
    }

  defp text(string),
    do: <<32::256, byte_size(string)::256>> <> string <> <<0::size(8 * (32 - byte_size(string)))>>

  defp word("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :lower)
end
