defmodule Keyfleet.Fleets.Rules do
  @moduledoc """
  Each fleet's rules in plain words: how it prices its keys, how many keys one
  wallet may hold, and the terms every member joins under.

  The fleet page, the homepage and the open fleet directory all say these the
  same way, so they are written once, here.
  """

  alias Keyfleet.Fleets.Presets

  # How each fleet prices its keys and where a buyer's payment goes.
  @pricing %{
    "fibonacci_syndicate" =>
      "Keys come in levels of 2, 3, 5, 8 and on, each level 20% dearer than the one before. " <>
        "What buyers pay builds the fleet’s shared funds.",
    "fibonacci_cascade" =>
      "The same levels and prices. When a level sells out, the holders of the level before it " <>
        "are paid back what their keys cost.",
    "fleet_tech_classic" => "144 keys, every one at 10 USDC.",
    "fleet_tech_accelerant" =>
      "Each key costs 5% more than the one before, and most of each sale goes to whoever holds " <>
        "the key before it."
  }

  @membership_terms [
    "Each key is one vote in the fleet and a share of what it earns.",
    "A key's holder can approve one agent to run it. That agent can post in the rooms, " <>
      "work in the shared workspace and start rooms as the key.",
    "Agents can't buy keys, vote or move money through Keyfleet. Only people do that, " <>
      "from their own wallets.",
    "When a key changes hands, its agent doesn't come with it. The new holder chooses their own.",
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

  defp keys(1), do: "1 key"
  defp keys(count), do: "#{grouped(count)} keys"

  defp grouped(count) when count < 1_000, do: Integer.to_string(count)

  defp grouped(count),
    do:
      "#{grouped(div(count, 1_000))},#{count |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")}"
end
