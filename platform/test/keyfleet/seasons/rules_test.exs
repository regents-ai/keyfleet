defmodule Keyfleet.Seasons.RulesTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Seasons.Rules

  # The ended season held USDC with no captain, so its own result was 0.
  @usdc_season %{
    holding: "USDC",
    captain_key: nil,
    holding_open_price: Decimal.new(1),
    holding_close_price: Decimal.new(1)
  }

  test "a fleet's first season holds USDC with no captain" do
    assert Rules.crown(nil, []) == {"USDC", nil}
  end

  test "of equal results, the pick locked first takes the crown" do
    picks = [
      pick(7, 2, "ETH-USD", "200", "220"),
      pick(3, 1, "SOL-USD", "10", "11"),
      pick(9, 3, "BTC-USD", "50000", "54000")
    ]

    assert %{token_id: 3} = Rules.best(picks)
    assert Rules.crown(@usdc_season, picks) == {"SOL-USD", 3}
  end

  # The later pick beats the first by less than Decimal's 28 digits hold.
  test "results are compared exactly, however their prices are written" do
    first = pick(5, 1, "ETH-USD", "3.000", "3.3")
    later = pick(6, 2, "SOL-USD", "30", "33.00000000000000000000000000000001")

    assert %{token_id: 6} = Rules.best([later, first])
    assert %{token_id: 5} = Rules.best([pick(6, 2, "SOL-USD", "30", "33"), first])

    assert Rules.crown(@usdc_season, [
             pick(4, 1, "SOL-USD", "100", "101.00000000000000000000000000001")
           ]) ==
             {"SOL-USD", 4}
  end

  test "the crown passes only above the switching margin" do
    assert Rules.switching_margin() == Decimal.new("0.01")

    at_the_line = pick(4, 1, "SOL-USD", "100", "101")
    just_over = pick(4, 1, "SOL-USD", "100", "101.0000001")

    assert Rules.crown(@usdc_season, [at_the_line]) == {"USDC", nil}
    assert Rules.crown(@usdc_season, [just_over]) == {"SOL-USD", 4}

    # Against a holding that itself rose 10%, a pick must rise more than 11%.
    eth = %{@usdc_season | holding: "ETH-USD", captain_key: 2}

    eth = %{
      eth
      | holding_open_price: Decimal.new("2000"),
        holding_close_price: Decimal.new("2200")
    }

    assert Rules.crown(eth, [pick(4, 1, "SOL-USD", "100", "111")]) == {"ETH-USD", 2}
    assert Rules.crown(eth, [pick(4, 1, "SOL-USD", "100", "111.01")]) == {"SOL-USD", 4}
  end

  test "a void pick never takes the crown" do
    void = %{pick(8, 1, "DOGE-USD", "0.1", "1") | close_price: nil}
    rising = pick(9, 2, "SOL-USD", "100", "102")

    assert Rules.best([void]) == nil
    assert Rules.crown(@usdc_season, [void]) == {"USDC", nil}
    assert Rules.crown(@usdc_season, [void, rising]) == {"SOL-USD", 9}
  end

  test "a best pick of the holding's own product leaves the holding and its captain" do
    sol = %{
      @usdc_season
      | holding: "SOL-USD",
        captain_key: 2,
        holding_open_price: Decimal.new("100"),
        holding_close_price: Decimal.new("150")
    }

    same = pick(5, 1, "SOL-USD", "100", "150")
    weaker = pick(6, 2, "ETH-USD", "100", "120")

    assert Rules.crown(sol, [same, weaker]) == {"SOL-USD", 2}

    # USDC picked against a USDC holding changes nothing either.
    assert Rules.crown(@usdc_season, [pick(5, 1, "USDC", "1", "1")]) == {"USDC", nil}
  end

  test "a holding with no price at the end counts as 0, so the margin over 0 decides" do
    unknown = %{
      @usdc_season
      | holding: "SOL-USD",
        captain_key: 2,
        holding_open_price: Decimal.new("100"),
        holding_close_price: nil
    }

    assert Rules.crown(unknown, [pick(5, 1, "ETH-USD", "100", "101")]) == {"SOL-USD", 2}
    assert Rules.crown(unknown, [pick(5, 1, "ETH-USD", "100", "101.01")]) == {"ETH-USD", 5}
    assert Rules.crown(unknown, []) == {"SOL-USD", 2}
  end

  test "a result is close over open less one, in the decimals sent, and unknown without both" do
    assert Decimal.eq?(
             Rules.result(Decimal.new("100"), Decimal.new("101.5")),
             Decimal.new("0.015")
           )

    assert Decimal.eq?(Rules.result(Decimal.new(1), Decimal.new(1)), 0)
    assert Rules.result(nil, Decimal.new(1)) == nil
    assert Rules.result(Decimal.new(1), nil) == nil
  end

  test "locking a pick gives it its open price, or why it is void" do
    eligible = MapSet.new(["USDC", "SOL-USD", "ETH-USD"])
    prices = %{"USDC" => Decimal.new(1), "SOL-USD" => Decimal.new("73.16"), "ETH-USD" => nil}

    assert Rules.opening(%{product: "SOL-USD"}, eligible, prices) == %{
             open_price: Decimal.new("73.16")
           }

    assert Rules.opening(%{product: "ETH-USD"}, eligible, prices) == %{void: :no_open_price}
    assert Rules.opening(%{product: "DOGE-USD"}, eligible, prices) == %{void: :ineligible}

    assert %{close_price: close, result: result} =
             Rules.closing(%{product: "SOL-USD", open_price: Decimal.new("36.58")}, prices)

    assert close == Decimal.new("73.16")
    assert Decimal.eq?(result, 1)

    assert Rules.closing(%{product: "ETH-USD", open_price: Decimal.new("2000")}, prices) == %{
             void: :no_close_price
           }
  end

  defp pick(token_id, lock_order, product, open, close) do
    %{
      token_id: token_id,
      lock_order: lock_order,
      product: product,
      open_price: Decimal.new(open),
      close_price: Decimal.new(close)
    }
  end
end
