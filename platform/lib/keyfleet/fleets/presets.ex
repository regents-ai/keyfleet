defmodule Keyfleet.Fleets.Presets do
  @moduledoc """
  The supply and price arithmetic of the four fleet presets, mirrored from
  `contracts/src/KeyfleetPresets.sol`.

  Every step is the contract's own integer step, `ceilDiv(previous * n, 100)`
  applied one level or one mint at a time, so a ladder computed here rounds
  exactly where the contract's does.

  Classic's 1,024 prices, 8 USDC for the first key to 80 USDC for the last,
  are read from `priv/classic_key_prices.txt`, which
  `scripts/classic_prices.py` writes together with the contract's own table.

  Prices are in atomic USDC, millionths of one USDC, and are exactly what a
  purchase pays: the Fibonacci and Accelerant fleets start at the contract's
  `Q_USDC`, 10 USDC, and follow their preset's ladder from there.
  """

  @q_usdc 10_000_000

  @fibonacci_levels 20
  @accelerant_max_keys 2_000

  # Classic's price table: one whole number of US cents per key, key 1 first.
  @classic_prices_path Path.expand("../../../priv/classic_key_prices.txt", __DIR__)
  @external_resource @classic_prices_path
  @classic_prices @classic_prices_path
                  |> File.read!()
                  |> String.split("\n", trim: true)
                  |> Enum.map(&(String.to_integer(&1) * 10_000))
                  |> List.to_tuple()
  @classic_supply tuple_size(@classic_prices)

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
  two presets without levels), and the next key's id and price in atomic USDC,
  both `nil` once sold out.
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
      next_price: if(sold_out?, do: nil, else: next_price(preset, total_minted))
    }
  end

  @doc """
  What the fleet's contract charged, or will charge, for key `token_id` when
  it is sold, in atomic USDC: the price `progress/2` offered once the key
  before it had sold.
  """
  def issue_price(fleet_id, token_id) when is_integer(token_id) and token_id >= 1,
    do: next_price(preset(fleet_id), token_id - 1)

  @doc "A fleet's preset: `:fibonacci`, `:classic` or `:accelerant`."
  def preset(fleet_id), do: Map.fetch!(@presets, fleet_id)

  @doc "Whether a fleet's keys come in levels, as the two Fibonacci fleets' do."
  def levelled?(fleet_id), do: Map.fetch!(@presets, fleet_id) == :fibonacci

  @doc """
  The levels a Fibonacci key may write once `total_minted` keys are sold: its
  own level, and each later level once every key of that level is sold. Never
  an earlier level.
  """
  def writable_levels(token_id, total_minted)
      when is_integer(total_minted) and total_minted >= 0 do
    own = fibonacci_level_of(token_id)
    [own | Enum.to_list((own + 1)..completed_levels(:fibonacci, total_minted)//1)]
  end

  @doc "Whether a Fibonacci fleet ever issues `token_id`."
  def fibonacci_token?(token_id), do: token_id in 1..@fibonacci_max_token_id

  @doc "The Fibonacci level that owns a token id."
  def fibonacci_level_of(token_id) when token_id in 1..@fibonacci_max_token_id,
    do: Enum.find_index(@fibonacci_level_ends, &(token_id <= &1)) + 1

  @doc "A Fibonacci level's price: 10 USDC at level 1, then ×1.2 per level, rounded up at each step."
  def fibonacci_level_price(level) when level in 1..@fibonacci_levels,
    do: step(@q_usdc, level - 1, 120)

  @doc """
  How many keys of one Fibonacci level a single wallet may hold: one for levels
  1 to 7, then a tenth of the level's supply, rounded down.
  """
  def fibonacci_holding_limit(level) when level in 1..7, do: 1

  def fibonacci_holding_limit(level) when level in 8..@fibonacci_levels,
    do: div(level_supply(level), 10)

  @doc "An Accelerant primary mint's price: 10 USDC for the first, then ×1.05 per mint, rounded up."
  def accelerant_price(mint_index) when mint_index in 0..(@accelerant_max_keys - 1)//1,
    do: step(@q_usdc, mint_index, 105)

  defp next_price(:fibonacci, minted), do: fibonacci_level_price(fibonacci_level_of(minted + 1))
  defp next_price(:classic, minted), do: elem(@classic_prices, minted)
  defp next_price(:accelerant, minted), do: accelerant_price(minted)

  defp max_supply(:fibonacci), do: @fibonacci_max_token_id
  defp max_supply(:classic), do: @classic_supply
  defp max_supply(:accelerant), do: @accelerant_max_keys

  # Token ids are contiguous, so a level is complete once its last id is minted.
  defp completed_levels(:fibonacci, minted),
    do: Enum.count(@fibonacci_level_ends, &(&1 <= minted))

  defp completed_levels(_preset, _minted), do: nil

  defp level_supply(level),
    do: Enum.at(@fibonacci_level_ends, level - 1) - Enum.at(@fibonacci_level_ends, level - 2)

  defp step(price, 0, _numerator), do: price

  defp step(price, steps, numerator),
    do: step(ceil_div(price * numerator, 100), steps - 1, numerator)

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
