defmodule KeyfleetWeb.FleetPage do
  @moduledoc """
  What a fleet's page reads: the reader's own keys, the key on offer, the key
  the map has chosen, and the hall's feed with what the fleet is trying now.
  """

  alias Keyfleet.Activity
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Metadata
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.KeyMap

  # How many of a holder's cards the way in shows.
  @cards_shown 50

  @doc """
  The Keys of the fleet the signed-in person holds, for the way in: the
  lowest, how many, and the first fifty by number, each with its small card
  (`nil` until it is made), as
  `%{first: token_id, count: count, cards: cards}`, or `nil` for someone
  holding none. `deck` is the fleet's `id`, `deck_hash` and `deck_size`, which
  say which card each Key shows.
  """
  def held(deck, actor) do
    with %{token_ids: token_ids} = held <- Keys.held_summary(actor, deck.id, @cards_shown) do
      images = Metadata.small_cards(deck, token_ids)

      %{
        first: held.first,
        count: held.count,
        cards: for(token_id <- token_ids, do: %{token_id: token_id, image: images[token_id]})
      }
    end
  end

  @doc """
  The key on offer now, which moves on with every sale; `nil` for the Regents
  Club, whose keys are given, never offered.
  """
  def next_sale(fleet_id, progress) do
    if not Presets.given?(fleet_id), do: offer(fleet_id, progress)
  end

  defp offer(fleet_id, progress) do
    level =
      if progress.next_token_id && Presets.levelled?(fleet_id),
        do: Presets.fibonacci_level_of(progress.next_token_id)

    %{
      token_id: progress.next_token_id,
      price: progress.next_price,
      max_supply: progress.max_supply,
      level: level
    }
  end

  @doc "A key in the address that isn't one the map shows is no choice at all."
  def chosen_key(progress, key) when is_binary(key) do
    case Integer.parse(key) do
      {token_id, ""} -> if KeyMap.choosable?(progress, token_id), do: token_id
      _not_a_number -> nil
    end
  end

  def chosen_key(_progress, _key), do: nil

  @doc """
  "Trying now", beside the hall's feed: the fleet's open goals and
  the work on them, with the key on each task named.
  """
  def read_trying_now(fleet_id), do: fleet_id |> Graph.trying_now() |> ActivityLines.trying_now()

  @doc """
  The first `wanted` pages of the hall's feed, newest first, as `actor`
  reads them (`Keyfleet.Activity.page/3`): the items, the cursor for the
  page after them and how many pages were read.
  """
  def activity_pages(fleet_id, wanted, actor),
    do: activity_pages(fleet_id, actor, nil, wanted, [])

  defp activity_pages(fleet_id, actor, cursor, wanted, read) do
    %{items: items, cursor: next} = Activity.page(fleet_id, cursor, actor: actor)
    read = [items | read]

    if next != nil and length(read) < wanted,
      do: activity_pages(fleet_id, actor, next, wanted, read),
      else: {read |> Enum.reverse() |> Enum.concat(), next, length(read)}
  end
end
