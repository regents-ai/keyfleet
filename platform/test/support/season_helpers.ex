defmodule Keyfleet.SeasonHelpers do
  @moduledoc """
  A fleet's seasons played as its turns play them (`Keyfleet.Seasons.Turn`),
  against `Keyfleet.CoinbaseStub`. The turns run ahead of the clock, as
  `Keyfleet.Seasons.TurnTest` runs them: the boundary just passed opens the
  fleet's first season, to start at the next, and each boundary after it
  locks the season starting there, settles the one before and opens the
  next, so the newest season still takes picks.
  """

  alias Keyfleet.CoinbaseStub
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.CoinList
  alias Keyfleet.Seasons.Turn
  alias Keyfleet.SharedReading

  @doc "The boundary just passed, then the next `count`."
  def boundaries(count) do
    now = Seasons.boundary(DateTime.utc_now())
    Enum.map(0..count, &DateTime.add(now, 3 * &1, :hour))
  end

  @doc """
  Coinbase listing the products of `prices` as open to picks, each closing at
  the price given for a boundary in the minute before it, and the site's
  list of products read from it, until the test ends.
  """
  def coinbase!(prices) do
    CoinbaseStub.stub(
      prices |> Map.keys() |> Enum.map(&CoinbaseStub.product/1),
      Map.new(prices, fn {product, closes} ->
        {product,
         for({boundary, close} <- closes, do: {DateTime.add(boundary, -1, :minute), close})}
      end)
    )

    :ok = CoinList.read()
    ExUnit.Callbacks.on_exit(fn -> SharedReading.delete(CoinList.key()) end)
  end

  @doc "The fleet's turn at `boundary`."
  def turn!(fleet_id, boundary) do
    :ok =
      Turn.perform(%Oban.Job{
        args: %{"fleet_id" => fleet_id, "boundary" => DateTime.to_iso8601(boundary)}
      })
  end
end
