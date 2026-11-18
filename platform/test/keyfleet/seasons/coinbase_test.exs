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

    assert Coinbase.eligible_among(["USDC"]) == {:ok, MapSet.new(["USDC"])}
  end

  test "a price is the close of the minute before the boundary, or the newest of the 15 minutes before it" do
    CoinbaseStub.stub([], %{
      "SOL-USD" => [{minutes_before(1), "73.160"}, {minutes_before(2), "73.2"}, {@boundary, "80"}],
      "ETH-USD" => [
        {minutes_before(16), "2000"},
        {minutes_before(15), "2001.5"},
        {minutes_before(7), "2002"}
      ],
      "QUIET-USD" => [{minutes_before(16), "1.5"}],
      "BUSY-USD" => [{minutes_before(15), "0.00000123"}]
    })

    assert Coinbase.price("SOL-USD", @boundary) == {:ok, Decimal.new("73.160")}
    assert Coinbase.price("ETH-USD", @boundary) == {:ok, Decimal.new("2002")}
    assert Coinbase.price("BUSY-USD", @boundary) == {:ok, Decimal.new("0.00000123")}
    assert Coinbase.price("QUIET-USD", @boundary) == {:ok, nil}
    assert Coinbase.price("NOPE-USD", @boundary) == {:ok, nil}
  end

  test "USDC is 1 without asking, and Coinbase not answering is an error" do
    CoinbaseStub.down()

    assert Coinbase.price("USDC", @boundary) == {:ok, Decimal.new(1)}
    assert {:error, {:coinbase, 503}} = Coinbase.price("SOL-USD", @boundary)
    assert {:error, {:coinbase, 503}} = Coinbase.eligible()
    assert {:error, {:coinbase, 503}} = Coinbase.eligible_among(["SOL-USD"])
  end

  defp minutes_before(minutes), do: DateTime.add(@boundary, -minutes, :minute)
end
