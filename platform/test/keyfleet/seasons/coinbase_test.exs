defmodule Keyfleet.Seasons.CoinbaseTest do
  use ExUnit.Case, async: true

  alias Keyfleet.CoinbaseStub
  alias Keyfleet.Seasons.Coinbase

  @boundary ~U[2026-11-18 03:00:00.000000Z]

  test "a product may be picked when Coinbase lists it as spot, in US dollars, open for trading and traded enough" do
    assert Coinbase.eligible?(CoinbaseStub.product("SOL-USD"))

    for {field, value} <- [
          {"product_type", "FUTURE"},
          {"quote_currency_id", "USDC"},
          {"is_disabled", true},
          {"trading_disabled", true},
          {"view_only", true},
          {"cancel_only", true},
          {"limit_only", true},
          {"auction_mode", true},
          {"approximate_quote_24h_volume", "999999.999"},
          {"approximate_quote_24h_volume", ""},
          {"approximate_quote_24h_volume", "NaN"}
        ] do
      refute Coinbase.eligible?(CoinbaseStub.product("SOL-USD", %{field => value})),
             "#{field} #{inspect(value)}"
    end

    assert Coinbase.eligible?(
             CoinbaseStub.product("SOL-USD", %{"approximate_quote_24h_volume" => "1000000.0"})
           )

    refute Coinbase.eligible?(Map.delete(CoinbaseStub.product("SOL-USD"), "view_only"))
  end

  test "the list holds USDC and each product open to picks, and asking for some answers only those" do
    CoinbaseStub.stub(
      [
        CoinbaseStub.product("SOL-USD"),
        CoinbaseStub.product("ETH-USD", %{"cancel_only" => true}),
        CoinbaseStub.product("BTC-USD")
      ],
      %{}
    )

    assert Coinbase.eligible() == {:ok, ["USDC", "SOL-USD", "BTC-USD"]}

    assert Coinbase.eligible_among(["ETH-USD", "BTC-USD", "NOPE-USD", "USDC"]) ==
             {:ok, MapSet.new(["BTC-USD", "USDC"])}
  end

  test "a list on many pages is read to its end, and one past twenty pages is not read" do
    CoinbaseStub.pages([
      [CoinbaseStub.product("SOL-USD")],
      [CoinbaseStub.product("BTC-USD")],
      [CoinbaseStub.product("ETH-USD", %{"view_only" => true})]
    ])

    assert Coinbase.eligible() == {:ok, ["USDC", "SOL-USD", "BTC-USD"]}
    assert Coinbase.eligible_among(["BTC-USD", "ETH-USD"]) == {:ok, MapSet.new(["BTC-USD"])}

    twenty = for n <- 1..20, do: [CoinbaseStub.product("C#{n}-USD")]
    CoinbaseStub.pages(twenty)
    assert {:ok, ["USDC" | listed]} = Coinbase.eligible()
    assert length(listed) == 20

    CoinbaseStub.pages(twenty ++ [[CoinbaseStub.product("C21-USD")]])
    assert Coinbase.eligible() == {:error, :too_many_pages}
  end

  test "a page that says more follow but names no next page fails the read at once" do
    test = self()

    for pagination <- [
          %{"has_next" => true, "next_cursor" => ""},
          %{"has_next" => true, "next_cursor" => nil},
          %{"has_next" => true}
        ] do
      Req.Test.stub(Coinbase, fn conn ->
        send(test, :page)

        Req.Test.json(conn, %{
          "products" => [CoinbaseStub.product("SOL-USD")],
          "pagination" => pagination
        })
      end)

      assert Coinbase.eligible() == {:error, :no_next_cursor}
      assert Coinbase.eligible_among(["SOL-USD"]) == {:error, :no_next_cursor}
      assert_received :page
      assert_received :page
      refute_received :page
    end
  end

  test "a price is the close of the minute before the boundary, or the newest good one of the season that ended there" do
    # The season that ended at the boundary began three hours before it.
    CoinbaseStub.stub([], %{
      "SOL-USD" => [{minutes_before(1), "73.160"}, {minutes_before(2), "73.2"}, {@boundary, "80"}],
      "ETH-USD" => [
        {minutes_before(181), "2000"},
        {minutes_before(180), "2001.5"},
        {minutes_before(97), "2002"}
      ],
      "QUIET-USD" => [{minutes_before(181), "1.5"}],
      "SLOW-USD" => [{minutes_before(180), "0.00000123"}],
      "ZERO-USD" => [{minutes_before(2), "5"}, {minutes_before(1), "0.000"}],
      "BELOW-USD" => [{minutes_before(3), "4"}, {minutes_before(1), "-1"}],
      "NAN-USD" => [{minutes_before(9), "3"}, {minutes_before(2), "NaN"}, {minutes_before(1), ""}],
      "BAD-USD" => [{minutes_before(2), "0"}, {minutes_before(1), "-1"}]
    })

    # A close of 0 or below, or one that is not a number, gives way to the
    # newest good one before it, and with none there is no price.
    assert Coinbase.price("ZERO-USD", @boundary) == {:ok, Decimal.new("5")}
    assert Coinbase.price("BELOW-USD", @boundary) == {:ok, Decimal.new("4")}
    assert Coinbase.price("NAN-USD", @boundary) == {:ok, Decimal.new("3")}
    assert Coinbase.price("BAD-USD", @boundary) == {:ok, nil}

    assert Coinbase.price("SOL-USD", @boundary) == {:ok, Decimal.new("73.160")}
    assert Coinbase.price("ETH-USD", @boundary) == {:ok, Decimal.new("2002")}
    assert Coinbase.price("SLOW-USD", @boundary) == {:ok, Decimal.new("0.00000123")}
    assert Coinbase.price("QUIET-USD", @boundary) == {:ok, nil}
    assert Coinbase.price("NOPE-USD", @boundary) == {:ok, nil}
  end

  test "USDC is 1 and open to picks without asking, and Coinbase not answering is an error" do
    CoinbaseStub.down()

    assert Coinbase.price("USDC", @boundary) == {:ok, Decimal.new(1)}
    assert Coinbase.eligible_among(["USDC"]) == {:ok, MapSet.new(["USDC"])}
    assert Coinbase.eligible_among([]) == {:ok, MapSet.new()}
    assert {:error, {:coinbase, 503}} = Coinbase.price("SOL-USD", @boundary)
    assert {:error, {:coinbase, 503}} = Coinbase.eligible()
    assert {:error, {:coinbase, 503}} = Coinbase.eligible_among(["SOL-USD"])
  end

  defp minutes_before(minutes), do: DateTime.add(@boundary, -minutes, :minute)
end
