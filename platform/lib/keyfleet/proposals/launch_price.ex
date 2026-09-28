defmodule Keyfleet.Proposals.LaunchPrice do
  @moduledoc """
  The prices a launch proposal fixes, as Autolaunch's `RegentLBPStrategyV2`
  reads them.

  The floor price is REGENT per launched token times 2^96, and a whole number
  of the auction's bid ticks: divisible by 100, a bid tick being a hundredth
  of the floor. The auction sells 20 billion tokens, and must raise that many
  at the floor, rounded up, or the keys' own higher minimum. The strategy
  refuses a floor or minimum it can't launch when the launch is proposed, so
  a recorded launch always raises what `required_regent_raised/2` gives.
  """

  @q96 Integer.pow(2, 96)
  @bid_ticks 100
  # The auction's 20 billion tokens, in their smallest units.
  @tokens_sold 20_000_000_000 * Integer.pow(10, 18)

  @doc "2^96, the scale of a floor price."
  def q96, do: @q96

  @doc """
  The floor for a price of `numerator / denominator` REGENT per token: times
  2^96, rounded down to a whole number of bid ticks, as the Autolaunch site
  rounds it.
  """
  def floor_price_q96(numerator, denominator) do
    floor = div(numerator * @q96, denominator)
    floor - rem(floor, @bid_ticks)
  end

  @doc """
  The REGENT, in its smallest units, a launch with this floor and minimum must
  raise: the tokens sold at the floor, rounded up, or the minimum when higher.
  """
  def required_regent_raised(floor_price_q96, minimum_regent_raised) do
    at_floor = div(@tokens_sold * floor_price_q96 + @q96 - 1, @q96)
    max(at_floor, minimum_regent_raised)
  end
end
