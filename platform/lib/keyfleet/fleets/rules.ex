defmodule Keyfleet.Fleets.Rules do
  @moduledoc """
  Each fleet's rules in plain words: how it prices its keys, how many keys one
  wallet may hold, and the terms every member joins under, with the numbers
  in them written the one way every page writes them.

  The fleet page and the open fleet directory say these the same way, so they
  are written once, here. The homepage says none of them; it only writes its
  numbers through `keys/1` and `grouped/1`.
  """

  alias Keyfleet.Fleets.Presets

  # How each fleet prices its keys and where a buyer's payment goes.
  @pricing %{
    "fibonacci_syndicate" =>
      "Keys come in levels of 2, 3, 5, 8 and on, each level 20% dearer than the one before, " <>
        "and new levels keep opening. What buyers pay builds the fleet’s shared money.",
    "fibonacci_cascade" =>
      "The same levels and prices, and new levels keep opening. When a level sells out, the " <>
        "holders of the level before it are paid back what their Keys cost.",
    "fleet_tech_classic" => "1,024 Keys, from 8 USDC for the first to 80 USDC for the last.",
    "fleet_tech_accelerant" =>
      "Up to 2,000 Keys, each 5% dearer than the one before. After the first Key, 70% of each " <>
        "sale goes to whoever holds the Key before it and 20% to the fleet’s shared money."
  }

  @membership_terms [
    "The Key holders own the fleet. Each Key is one vote, and what the fleet earns in USDC " <>
      "is paid in full to the Keys.",
    "Everything else the fleet holds is its shared money, spent only on a payment the Keys " <>
      "vote for. Each Key that didn’t vote yes can collect a matching share of every payment.",
    "A proposal is approved once more than half of all the Keys sold vote yes, or 3 of " <>
      "every 5 Keys sold for a change to whether a Key may edit the workspace. A Key bought " <>
      "or moved after a proposal opened can’t vote on it.",
    "Regents takes 10% of each Key sale, once, and nothing from what the fleet earns after.",
    "A Key's owner can issue shards of it to agents' wallets, for 1 to 365 days. An agent " <>
      "with a shard can post in the rooms, work in the shared workspace and start rooms as " <>
      "the Key.",
    "A shard never votes, proposes, buys, collects or moves money. Only a Key's owner does " <>
      "that, from their own wallet.",
    "When a Key changes hands, all its shards end. The new owner issues their own.",
    "Posts and workspace changes stay with whoever wrote them."
  ]

  @doc "One sentence on how a fleet prices its keys and where a buyer's payment goes."
  def pricing(fleet_id), do: Map.fetch!(@pricing, fleet_id)

  @doc """
  How many keys of `token_id`'s level one wallet may hold, as a sentence, for
  the two Fibonacci fleets; `nil` for Classic and Accelerant, which set no
  limit.
  """
  def holding_limit_sentence(fleet_id, token_id) do
    if Presets.levelled?(fleet_id) do
      level = Presets.fibonacci_level_of(token_id)
      "One wallet may hold #{keys(Presets.fibonacci_holding_limit(level))} of level #{level}."
    end
  end

  @doc "The terms every member of every fleet joins under, one sentence each."
  def membership_terms, do: @membership_terms

  @doc "A number of keys in words, such as `1 Key` or `1,771 Keys`."
  def keys(1), do: "1 Key"
  def keys(count), do: "#{grouped(count)} Keys"

  @doc "A whole number with its thousands separated by commas."
  def grouped(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
