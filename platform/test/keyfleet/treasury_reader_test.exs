defmodule Keyfleet.TreasuryReaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Chain.{StubClient, TreasuryReader}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Proposals
  alias Keyfleet.Repo
  alias Keyfleet.Treasury

  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @rewards "0x" <> String.duplicate("8", 40)
  @treasury "0x" <> String.duplicate("7e", 20)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @eth "0x0000000000000000000000000000000000000000"
  @launch "0x" <> String.duplicate("4", 40)
  @max_uint256 2 ** 256 - 1
  @head_hash "0x" <> String.duplicate("f", 64)

  # Pinned from `cast sig` of each view function.
  @split_assets "0x930fcaef"
  @daily_split_bps "0x8b0e4bdd"
  @last_run_at "0x1767e5cc"
  @next_run_at "0x8e3b5ea7"
  @launch_token "0xa28a4d86"
  @cascade_reserve "0xfc4e8964"
  @protocol_share_owed "0xc490b9c7"
  @backed "0x595b7f21"
  @balance_of "0x70a08231"
  @decimals "0x313ce567"
  @symbol "0x95d89b41"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    fleet =
      ChainHelpers.deploy!(@fleet, %{
        manager_address: @contract,
        rewards_address: @rewards,
        treasury_address: @treasury
      })

    %{fleet: fleet}
  end

  # Every figure is read at the head's block and kept together, for each
  # asset the daily split shares and no other, and the proposal pages are
  # told. ETH, USDC and REGENT are named by the deployment, so no token is
  # asked what it is.
  test "a reading keeps every figure from the one block it was read at", %{fleet: fleet} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
    put_chain(40, chain())

    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:balances_changed, @fleet}

    requests = StubClient.call_requests()
    assert Enum.all?(requests, fn {_to, _data, block_hash} -> block_hash == @head_hash end)

    assert Enum.uniq(for {to, _data, _hash} <- requests, do: to) ==
             [@treasury, @rewards, @regent, @usdc, @contract]

    assert List.last(requests) == {@contract, @protocol_share_owed, @head_hash}
    refute Enum.any?(requests, fn {_to, data, _hash} -> data in [@symbol, @decimals] end)

    reading = Treasury.get_reading!(@fleet)

    assert %{block_number: 40, block_hash: @head_hash, daily_split_bps: 75} = reading
    assert DateTime.compare(reading.block_time, head(40).timestamp) == :eq
    assert reading.last_run_at == DateTime.from_unix!(1_700_000_000)
    assert reading.next_run_at == DateTime.from_unix!(1_700_086_400)
    assert reading.launch_token == nil
    assert Decimal.equal?(reading.cascade_reserve, 700)
    assert Decimal.equal?(reading.protocol_share_owed, 800)

    assert [
             %{asset: @eth, held: 5_000, backed: 1_000},
             %{asset: @regent, held: @max_uint256, backed: 0},
             %{asset: @usdc, held: 100_000_000, backed: 30_000_000}
           ] = reading.assets

    assert details() == %{}
  end

  # The launch token, once bound, is split and read like the others, the
  # reading names it, and it is asked what it is, after the money.
  test "a bound launch token is read with the others", %{fleet: fleet} do
    put_chain(40, bound())
    assert {:ok, reading} = TreasuryReader.read(fleet, StubClient)

    assert reading.launch_token == @launch
    assert %{asset: @launch, held: 2_000, backed: 300} = List.last(reading.assets)

    {money, details} = Enum.split(StubClient.call_requests(), -2)
    assert List.last(money) == {@contract, @protocol_share_owed, @head_hash}
    assert details == [{@launch, @symbol, @head_hash}, {@launch, @decimals, @head_hash}]
    assert details() == %{@launch => {"LAUNCH", 18}}
  end

  # A token's symbol and decimals, once both are known, are not asked again.
  test "a token's symbol and decimals are read once", %{fleet: fleet} do
    put_chain(40, bound())
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    put_chain(41, Map.put(bound(), {@launch, @symbol}, {:ok, text("LNCH")}))
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)

    refute Enum.any?(StubClient.call_requests(), fn {_to, data, _hash} ->
             data in [@symbol, @decimals]
           end)

    assert details()[@launch] == {"LAUNCH", 18}
  end

  # A figure that cannot be read, or reads as something else, keeps nothing,
  # and no token is asked what it is until a reading is kept.
  test "a reading that fails in any part keeps nothing", %{fleet: fleet} do
    for {key, answer, reason} <- [
          {{@rewards, @backed <> arg(@usdc)}, {:error, :chain_unavailable},
           {@rewards, :chain_unavailable}},
          {{@regent, @balance_of <> arg(@treasury)}, {:ok, <<1, 2>>},
           {@regent, :unreadable_answer}},
          {{@treasury, @daily_split_bps}, {:ok, <<70_000::256>>},
           {@treasury, :unreadable_answer}},
          {{@contract, @cascade_reserve}, {:ok, <<1, 2>>}, {@contract, :unreadable_answer}}
        ] do
      put_chain(40, Map.put(chain(), key, answer))

      assert TreasuryReader.read(fleet, StubClient) == {:error, reason}
      assert Treasury.get_reading!(@fleet) == nil
      assert details() == %{}

      refute Enum.any?(StubClient.call_requests(), fn {_to, data, _hash} ->
               data in [@symbol, @decimals]
             end)
    end

    refute_received {:balances_changed, _fleet}
  end

  # A call to a token that fails may be the node's: nothing is kept about the
  # token, the reading is kept and announced all the same, and the token is
  # asked again at the next reading.
  test "a token whose call fails is asked again at the next reading", %{fleet: fleet} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
    put_chain(40, Map.put(bound(), {@launch, @decimals}, {:error, :chain_unavailable}))

    log =
      capture_log(fn ->
        assert {:ok, %{block_number: 40}} = TreasuryReader.read(fleet, StubClient)
      end)

    assert log =~ "token #{@launch} was not read"
    assert_received {:balances_changed, @fleet}
    assert details() == %{}

    put_chain(41, bound())
    assert {:ok, %{block_number: 41}} = TreasuryReader.read(fleet, StubClient)
    assert details() == %{@launch => {"LAUNCH", 18}}
  end

  # A symbol is shown as written, so a token's is kept only when it is 1 to
  # 32 bytes of text without control or direction characters.
  test "a symbol that is not short plain text is kept as unknown", %{fleet: fleet} do
    for {symbol, kept} <- [
          {"USD₮", "USD₮"},
          {String.duplicate("S", 32), String.duplicate("S", 32)},
          {"", nil},
          {"US" <> <<0>> <> "DC", nil},
          {<<0>>, nil},
          {String.duplicate("S", 33), nil},
          {"USD\nC", nil},
          {<<0xC2, 0x85>> <> "USDC", nil},
          {<<0xFF>> <> "USDC", nil},
          {"\u202EUSDC", nil},
          {"\u2066USDC", nil},
          {"USDC\u200F", nil},
          {"\u061CUSDC", nil}
        ] do
      Repo.query!("DELETE FROM keyfleet_app.treasury_asset_details WHERE fleet_id = $1", [@fleet])
      put_chain(40, Map.put(bound(), {@launch, @symbol}, {:ok, text(symbol)}))
      assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
      assert details()[@launch] == {kept, 18}, inspect(symbol)
    end
  end

  # A reading that fails leaves the one kept as it was.
  test "a failed reading leaves the previous one untouched", %{fleet: fleet} do
    put_chain(40, chain())
    assert {:ok, kept} = TreasuryReader.read(fleet, StubClient)

    failing =
      chain()
      |> Map.put({@contract, @cascade_reserve}, {:ok, <<1::256>>})
      |> Map.put({@contract, @protocol_share_owed}, {:error, :chain_unavailable})

    put_chain(41, failing)

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
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
    put_chain(40, chain())
    assert {:ok, _reading} = TreasuryReader.read(fleet, StubClient)
    assert_received {:balances_changed, @fleet}

    earlier = Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<1::256>>})

    for number <- [39, 40] do
      put_chain(number, earlier)
      assert {:ok, _skipped} = TreasuryReader.read(fleet, StubClient)
      refute_received {:balances_changed, _fleet}
    end

    reading = Treasury.get_reading!(@fleet)
    assert reading.block_number == 40
    assert Decimal.equal?(reading.cascade_reserve, 700)

    put_chain(41, Map.put(chain(), {@contract, @cascade_reserve}, {:ok, <<2::256>>}))
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

  # The treasury splits ETH, REGENT and USDC at 0.75% a day, last run at
  # 1,700,000,000 with no launch token bound; it holds 5,000 wei, every
  # unit of REGENT a uint256 can count and 100 USDC.
  defp chain do
    %{
      {@treasury, @split_assets} => {:ok, addresses([@eth, @regent, @usdc])},
      {@treasury, @daily_split_bps} => {:ok, <<75::256>>},
      {@treasury, @last_run_at} => {:ok, <<1_700_000_000::256>>},
      {@treasury, @next_run_at} => {:ok, <<1_700_086_400::256>>},
      {@treasury, @launch_token} => {:ok, <<0::256>>},
      {@rewards, @backed <> arg(@eth)} => {:ok, <<1_000::256>>},
      {@contract, @cascade_reserve} => {:ok, <<700::256>>},
      {@contract, @protocol_share_owed} => {:ok, <<800::256>>}
    }
    |> Map.merge(token(@regent, "REGENT", @max_uint256, 0))
    |> Map.merge(token(@usdc, "USDC", 100_000_000, 30_000_000))
  end

  # The same, with a launch token bound and split as well: 2,000 held and
  # 300 backed.
  defp bound do
    chain()
    |> Map.put({@treasury, @split_assets}, {:ok, addresses([@eth, @regent, @usdc, @launch])})
    |> Map.put({@treasury, @launch_token}, {:ok, word(@launch)})
    |> Map.merge(token(@launch, "LAUNCH", 2_000, 300))
  end

  # What the treasury holds of `token`, what the reward ledger backs, and the
  # token's symbol, with 18 decimals.
  defp token(token, symbol, held, backed) do
    %{
      {token, @balance_of <> arg(@treasury)} => {:ok, <<held::256>>},
      {@rewards, @backed <> arg(token)} => {:ok, <<backed::256>>},
      {token, @symbol} => {:ok, text(symbol)},
      {token, @decimals} => {:ok, <<18::256>>}
    }
  end

  defp put_chain(number, chain) do
    StubClient.put_chain(head(number), [],
      calls: fn to, data, _block_hash -> Map.get(chain, {to, data}, {:error, :no_answer}) end,
      balances: %{@treasury => 5_000}
    )
  end

  defp head(number),
    do: %{
      number: number,
      hash: @head_hash,
      timestamp: DateTime.from_unix!(1_700_000_000 + number),
      base_fee: 0
    }

  defp text(string) do
    padded = 32 * div(byte_size(string) + 31, 32)
    <<32::256, byte_size(string)::256>> <> string <> <<0::size(8 * (padded - byte_size(string)))>>
  end

  defp addresses(list),
    do: <<32::256, length(list)::256>> <> Enum.map_join(list, &word/1)

  # An address as a returned word, and as a call's argument.
  defp word("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :lower)
  defp arg("0x" <> hex), do: String.duplicate("0", 24) <> hex
end
