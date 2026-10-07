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
        "and new levels keep opening. What buyers pay goes to the fleet’s treasury.",
    "fibonacci_cascade" =>
      "The same levels and prices, and new levels keep opening. When a level sells out, the " <>
        "holders of the level before it are paid back what their Keys cost.",
    "fleet_tech_classic" => "1,024 Keys, from 8 USDC for the first to 80 USDC for the last.",
    "fleet_tech_accelerant" =>
      "Up to 2,000 keys, each 5% dearer than the one before. After the first key, 70% of each " <>
        "sale goes to whoever holds the key before it and 20% to the fleet’s treasury."
  }

  @membership_terms [
    "The key holders own the fleet. Each key has one vote, and everything the fleet receives " <>
      "outside a key sale, USDC included, goes to its treasury.",
    "Once a day, anyone can run the daily split. It shares from 0.1% to 2% of each token the " <>
      "treasury splits equally among all the keys, at the rate the keys vote for. A token is " <>
      "shared only while the treasury holds at least 100 of it, or 0.05 ETH.",
    "A key counts in new proposals while it is present, and marking present lasts 48 hours. " <>
      "A key away for longer keeps its part of every split and can come back at any time.",
    "A proposal is approved when more than half of the keys counted for it vote yes: the " <>
      "keys present when it opened, and any key that votes on it later. Voting lasts up to " <>
      "48 hours, and an approved proposal can be carried out for 48 hours after that.",
    "Approved proposals can spend everything in the treasury.",
    "10% of each key sale goes to REGENT staking, once, and nothing from the treasury after.",
    "A key's owner can issue shards of it to agents' wallets, for 1 to 365 days. An agent " <>
      "with a shard can post in the rooms, work in the shared workspace and start rooms as " <>
      "the key.",
    "While the key's agent voting is on, as it is unless its owner turns it off, an agent " <>
      "with a shard can also mark the key present, vote, propose and cancel the key's " <>
      "proposals.",
    "An agent with a shard can claim the key's money, which is always paid to the wallet " <>
      "holding the key. A shard never buys or moves keys.",
    "When a key changes hands, all its shards end. The new owner issues their own.",
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
