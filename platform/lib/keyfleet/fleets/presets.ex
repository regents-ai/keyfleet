defmodule KeyFleet.Fleets.Presets do
  @moduledoc """
  The supply and price arithmetic of the four fleet presets, mirrored from
  `contracts/src/KeyfleetPresets.sol`.

  Every step is the contract's own integer step, `ceilDiv(previous * n, 100)`
  applied one level or one mint at a time, so a ladder computed here rounds
  exactly where the contract's does.

  Prices shown on the site are in US dollars, held as micro-dollars (six
  decimal places, the unit USDC counts in): every fleet starts at a $10 base
  and follows its preset's ladder from there. The contract prices keys in
  REGENT from its own reference price, so these figures describe the ladder,
  not the amount a purchase will pull.
  """

  @micro_dollars 1_000_000
  @base_price 10 * @micro_dollars

  @fibonacci_levels 20
  @classic_supply 144
  @accelerant_max_keys 2_000

  # Level supplies 2, 3, 5, 8, … and the last token id of each level.
  @fibonacci_level_ends 2..@fibonacci_levels
                        |> Enum.scan({1, 2, 2}, fn _level, {previous, current, total} ->
                          {current, previous + current, total + previous + current}
                        end)
                        |> Enum.map(&elem(&1, 2))
                        |> then(&[2 | &1])

  @fibonacci_max_token_id List.last(@fibonacci_level_ends)

  @presets %{
    "fibonacci_syndicate" => :fibonacci,
    "fibonacci_cascade" => :fibonacci,
    "fleet_tech_classic" => :classic,
    "fleet_tech_accelerant" => :accelerant
  }

  @doc """
  Where a fleet stands after `total_minted` primary keys: how many it can ever
  issue, how many levels it has and how many are complete (both `nil` for the
  two presets without levels), and the next key's id and price in
  micro-dollars, both `nil` once sold out.
  """
  def progress(fleet_id, total_minted) when is_integer(total_minted) and total_minted >= 0 do
    preset = Map.fetch!(@presets, fleet_id)
    max_supply = max_supply(preset)
    sold_out? = total_minted >= max_supply

    %{
      total_minted: total_minted,
      max_supply: max_supply,
      levels: if(preset == :fibonacci, do: @fibonacci_levels),
      completed_levels: completed_levels(preset, total_minted),
      next_token_id: if(sold_out?, do: nil, else: total_minted + 1),
      next_price: if(sold_out?, do: nil, else: next_price(preset, @base_price, total_minted))
    }
  end

  @doc "The Fibonacci level that owns a token id."
  def fibonacci_level_of(token_id) when token_id in 1..@fibonacci_max_token_id,
    do: Enum.find_index(@fibonacci_level_ends, &(token_id <= &1)) + 1

  @doc "A Fibonacci level's price: `q` at level 1, then ×1.2 per level, rounded up at each step."
  def fibonacci_level_price(q, level) when level in 1..@fibonacci_levels,
    do: step(q, level - 1, 120)

  @doc "An Accelerant primary mint's price: `q` for the first, then ×1.05 per mint, rounded up."
  def accelerant_price(q, mint_index) when mint_index in 0..(@accelerant_max_keys - 1)//1,
    do: step(q, mint_index, 105)

  defp next_price(:fibonacci, q, minted),
    do: fibonacci_level_price(q, fibonacci_level_of(minted + 1))

  defp next_price(:classic, q, _minted), do: q
  defp next_price(:accelerant, q, minted), do: accelerant_price(q, minted)

  defp max_supply(:fibonacci), do: @fibonacci_max_token_id
  defp max_supply(:classic), do: @classic_supply
  defp max_supply(:accelerant), do: @accelerant_max_keys

  # Token ids are contiguous, so a level is complete once its last id is minted.
  defp completed_levels(:fibonacci, minted),
    do: Enum.count(@fibonacci_level_ends, &(&1 <= minted))

  defp completed_levels(_preset, _minted), do: nil

  defp step(price, 0, _numerator), do: price

  defp step(price, steps, numerator),
    do: step(ceil_div(price * numerator, 100), steps - 1, numerator)

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
