defmodule KeyFleet.TreasuryReaderTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain.{StubClient, TreasuryReader}
  alias KeyFleet.Fleets
  alias KeyFleet.Proposals
  alias KeyFleet.Repo
  alias KeyFleet.Treasury

  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @rewards "0x" <> String.duplicate("8", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @other "0x" <> String.duplicate("5", 40)
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

  # Every figure is read at the head's block and kept together, and the
  # proposal pages are told.
  test "a reading keeps every balance from the one block it was read at", %{fleet: fleet} do
    Phoenix.PubSub.subscribe(KeyFleet.PubSub, Proposals.topic(@fleet))
    StubClient.put_chain(head(40), [], calls: answers(chain()))

    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:proposals_changed, @fleet}

    requests = StubClient.call_requests()
    assert length(requests) == 14
    assert Enum.all?(requests, fn {_to, _data, block_hash} -> block_hash == @head_hash end)

    reading = Treasury.get_reading!(@fleet)

    assert %{
             block_number: 40,
             block_hash: @head_hash,
             launch_settled: true,
             assets: [usdc, other]
           } = reading

    assert DateTime.compare(reading.block_time, head(40).timestamp) == :eq
    assert Decimal.equal?(reading.cascade_reserve, 700)
    assert Decimal.equal?(reading.protocol_share_owed, 800)

    assert %{asset: @usdc, symbol: "USDC", decimals: 6, pay_period_start: nil} = usdc
    assert Decimal.equal?(usdc.free_capital, 100_000_000)
    assert Decimal.equal?(usdc.backed, 30_000_000)
    assert Decimal.equal?(usdc.pay_cap, 0)
    assert Decimal.equal?(usdc.pay_spent, 0)

    assert %{asset: @other, symbol: "WETH", decimals: 18} = other
    assert DateTime.compare(other.pay_period_start, DateTime.from_unix!(@period_start)) == :eq
    assert Decimal.equal?(other.free_capital, 5_000)
    assert Decimal.equal?(other.pay_cap, 1_000)
    assert Decimal.equal?(other.pay_spent, 400)
    assert Decimal.equal?(other.backed, 60)
  end

  # A figure that cannot be read, or reads as something else, keeps nothing.
  test "a reading that fails in any part keeps nothing", %{fleet: fleet} do
    for {key, answer, reason} <- [
          {{@rewards, @backed <> word(@other)}, {:error, :chain_unavailable},
           {@rewards, :chain_unavailable}},
          {{@contract, @launch_settled}, {:ok, <<2::256>>}, {@contract, :unreadable_answer}},
          {{@other, @symbol}, {:ok, <<32::256>>}, {@other, :unreadable_answer}}
        ] do
      StubClient.put_chain(head(40), [], calls: answers(Map.put(chain(), key, answer)))

      assert TreasuryReader.read(fleet, StubClient) == {:error, reason}
      assert Treasury.get_reading!(@fleet) == nil
    end

    refute_received {:proposals_changed, _fleet}
  end

  # A reading from an earlier block never replaces a later one.
  test "an earlier reading does not replace a later one", %{fleet: fleet} do
    StubClient.put_chain(head(40), [], calls: answers(chain()))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    earlier = Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<1::256>>})
    StubClient.put_chain(head(39), [], calls: answers(earlier))
    assert {:ok, _skipped} = TreasuryReader.read(fleet, StubClient)

    reading = Treasury.get_reading!(@fleet)
    assert reading.block_number == 40
    assert Decimal.equal?(reading.cascade_reserve, 700)

    later = Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<2::256>>})
    StubClient.put_chain(head(41), [], calls: answers(later))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    reading = Treasury.get_reading!(@fleet)
    assert reading.block_number == 41
    assert Decimal.equal?(reading.cascade_reserve, 2)
  end

  defp chain do
    %{
      {@rewards, @reward_assets} => {:ok, <<32::256, 2::256>> <> word(@usdc) <> word(@other)},
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
