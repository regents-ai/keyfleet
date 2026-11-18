defmodule Keyfleet.Seasons.TurnTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  require Ash.Query

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CoinbaseStub
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.CoinList
  alias Keyfleet.Seasons.Season
  alias Keyfleet.Seasons.SeasonPick
  alias Keyfleet.Seasons.Turn
  alias Keyfleet.Seasons.Turns
  alias Phoenix.Socket.Broadcast

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}],
        do: epoch!(token_id: token_id, owner_wallet: wallet(owner))

    on_exit(fn -> Keyfleet.SharedReading.delete(CoinList.key()) end)

    # The boundary just passed, and the next four: the turns run ahead of the
    # clock, so each season still takes picks until its turn locks it.
    now = Seasons.boundary(DateTime.utc_now())
    %{boundaries: Enum.map(0..4, &DateTime.add(now, 3 * &1, :hour))}
  end

  test "a turn settles the season that ended, locks the one starting and opens the next",
       %{boundaries: [b0, b1, b2, b3 | _]} do
    coins = [CoinbaseStub.product("SOL-USD"), CoinbaseStub.product("ETH-USD")]
    stub(coins ++ [CoinbaseStub.product("DOGE-USD")], %{})

    # A fleet with no seasons opens its first, to start at the next boundary.
    assert :ok = turn(b0)
    assert [%{number: 1, starts_at: starts_at, locked_at: nil}] = seasons()
    assert DateTime.compare(starts_at, b1) == :eq

    pick!(1, "a", "SOL-USD")
    pick!(1, "b", "ETH-USD")
    pick!(1, "c", "DOGE-USD")

    # DOGE stopped trading before the season started.
    stub(coins ++ [CoinbaseStub.product("DOGE-USD", %{"trading_disabled" => true})], %{
      "SOL-USD" => [{before(b1, 1), "100"}, {before(b2, 1), "103"}],
      "ETH-USD" => [{before(b1, 3), "2000"}, {before(b2, 1), "2040"}],
      "DOGE-USD" => [{before(b1, 1), "0.1"}]
    })

    assert :ok = turn(b1)

    assert [
             %{number: 1, holding: "USDC", captain_key: nil, settled_at: nil} = one,
             %{number: 2, locked_at: nil}
           ] = seasons()

    assert Decimal.eq?(one.holding_open_price, 1)

    assert [
             %{token_id: 1, open_price: sol, void: nil},
             %{token_id: 2, open_price: eth, void: nil},
             %{token_id: 3, open_price: nil, void: :ineligible}
           ] = picks(1)

    assert {sol, eth} == {Decimal.new("100"), Decimal.new("2000")}

    pick!(2, "b", "SOL-USD")
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Seasons.topic(@fleet))

    assert :ok = turn(b2)
    assert_receive %Broadcast{event: "seasons_changed", payload: payload}
    assert payload == %{}

    assert [one, two, %{number: 3, locked_at: nil, starts_at: three_starts}] = seasons()
    assert DateTime.compare(three_starts, b3) == :eq

    # USDC held still, SOL rose 3% and ETH 2%: SOL by more than the margin.
    assert %{settled_at: %DateTime{}} = one
    assert Decimal.eq?(one.holding_close_price, 1) and Decimal.eq?(one.holding_result, 0)

    assert [%{token_id: 1, result: sol}, %{token_id: 2, result: eth}, %{void: :ineligible}] =
             picks(1)

    assert Decimal.eq?(sol, "0.03") and Decimal.eq?(eth, "0.02")

    assert %{holding: "SOL-USD", captain_key: 1, settled_at: nil} = two
    assert two.holding_open_price == Decimal.new("103")
    assert [%{token_id: 2, open_price: open}] = picks(2)
    assert open == Decimal.new("103")
  end

  test "a turn run twice, or a boundary already passed, changes nothing more",
       %{boundaries: [b0, b1, b2 | _]} do
    stub([CoinbaseStub.product("SOL-USD")], %{
      "SOL-USD" => [{before(b1, 1), "10"}, {before(b2, 1), "12"}]
    })

    assert :ok = turn(b0)
    pick!(1, "a", "SOL-USD")
    assert :ok = turn(b1)
    assert :ok = turn(b2)

    held = {seasons(), picks(1)}

    for boundary <- [b2, b1, b0], do: assert(:ok = turn(boundary))

    assert {seasons(), picks(1)} == held
    assert [%{holding: "USDC"}, %{holding: "SOL-USD", captain_key: 1}, %{number: 3}] = seasons()
  end

  test "after three missed boundaries a turn catches up from the candles, one season at a time",
       %{boundaries: [b0, b1, b2, b3, b4]} do
    stub([CoinbaseStub.product("SOL-USD"), CoinbaseStub.product("ETH-USD")], %{
      "SOL-USD" => [
        {before(b1, 1), "100"},
        {before(b2, 1), "110"},
        {before(b3, 1), "99"},
        {before(b4, 1), "120"}
      ],
      # ETH has its start price, and no trade in the 15 minutes before b2.
      "ETH-USD" => [{before(b1, 1), "2000"}, {before(b2, 20), "2500"}]
    })

    assert :ok = turn(b0)
    pick!(1, "a", "SOL-USD")
    pick!(1, "b", "ETH-USD")

    assert :ok = turn(b4)

    assert [one, two, three, four, %{number: 5, locked_at: nil}] = seasons()

    # Season 1 held USDC, SOL rose 10% and took the crown for season 2.
    assert %{holding: "USDC", captain_key: nil} = one

    assert [
             %{token_id: 1, close_price: close},
             %{token_id: 2, void: :no_close_price, result: nil}
           ] =
             picks(1)

    assert close == Decimal.new("110")

    # SOL was held from 110 to 99, then from 99 to 120, with nobody picking.
    for {season, open, close} <- [{two, "110", "99"}, {three, "99", "120"}] do
      assert %{holding: "SOL-USD", captain_key: 1} = season

      assert {season.holding_open_price, season.holding_close_price} ==
               {Decimal.new(open), Decimal.new(close)}
    end

    assert Decimal.eq?(two.holding_result, "-0.1")
    assert %{holding: "SOL-USD", settled_at: nil} = four
    assert four.holding_open_price == Decimal.new("120")

    locked = Enum.map([one, two, three, four], & &1.locked_at)
    assert locked == Enum.sort(locked, DateTime)
  end

  test "when Coinbase can't be read, the turn fails and settles nothing", %{
    boundaries: [b0, b1, b2 | _]
  } do
    stub([CoinbaseStub.product("SOL-USD"), CoinbaseStub.product("ETH-USD")], %{
      "SOL-USD" => [{before(b1, 1), "100"}, {before(b2, 1), "110"}],
      "ETH-USD" => [{before(b1, 1), "2000"}]
    })

    assert :ok = turn(b0)
    pick!(1, "a", "SOL-USD")
    assert :ok = turn(b1)
    pick!(2, "b", "ETH-USD")
    held = {seasons(), picks(1), picks(2)}

    CoinbaseStub.down()
    assert {:error, {:coinbase, 503}} = turn(b2)
    assert {seasons(), picks(1), picks(2)} == held

    # The list answers but one product's candles don't.
    stub([CoinbaseStub.product("SOL-USD"), CoinbaseStub.product("ETH-USD")], %{
      "SOL-USD" => [{before(b2, 1), "110"}],
      "ETH-USD" => :down
    })

    assert {:error, {:coinbase, 503}} = turn(b2)
    assert {seasons(), picks(1), picks(2)} == held
  end

  test "a minute after each boundary every deployed fleet's turn is queued, once" do
    ChainHelpers.deploy!(@fleet)

    assert :ok = perform_job(Turns, %{})
    assert :ok = perform_job(Turns, %{})

    boundary = DateTime.utc_now() |> Seasons.boundary() |> DateTime.to_iso8601()
    assert [%Oban.Job{args: args, queue: "seasons"}] = all_enqueued(worker: Turn)
    assert args == %{"fleet_id" => @fleet, "boundary" => boundary}
  end

  defp turn(boundary),
    do: perform_job(Turn, %{fleet_id: @fleet, boundary: DateTime.to_iso8601(boundary)})

  defp stub(products, closes) do
    CoinbaseStub.stub(products, closes)
    :ok = CoinList.read()
  end

  defp before(boundary, minutes), do: DateTime.add(boundary, -minutes, :minute)

  defp pick!(number, owner, product),
    do: Seasons.pick!(@fleet, number, %{product: product}, actor: human(owner))

  defp seasons do
    Season
    |> Ash.Query.filter(fleet_id == ^@fleet)
    |> Ash.Query.sort(:number)
    |> Ash.read!(actor: @system)
  end

  defp picks(number) do
    SeasonPick
    |> Ash.Query.filter(season.fleet_id == ^@fleet and season.number == ^number)
    |> Ash.Query.sort(:token_id)
    |> Ash.read!(actor: @system)
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 1,
      owner_wallet: wallet("a"),
      block_number: 10,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{event.token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
