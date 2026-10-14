defmodule KeyfleetWeb.FleetPage do
  @moduledoc """
  What a fleet's page reads: the reader's own keys, the key on offer, a page of its keys with the
  agents holding their shards, the links to the pages either side, the key the map
  has chosen, and the hall's feed with what the fleet is trying now.

  A page name that isn't one the keys can answer is a page that doesn't exist.
  """

  alias Keyfleet.Activity
  alias Keyfleet.Agents.Avatar
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Metadata
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.KeyMap
  alias KeyfleetWeb.NotFoundError

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

  @doc """
  A page is named by the key it follows or precedes; a name that isn't one
  is a page that doesn't exist.
  """
  def key_page!(fleet_id, params, actor) do
    case Keys.keys_in_fleet(fleet_id, page: key_position(params), actor: actor) do
      {:ok, page} -> page
      {:error, %Ash.Error.Invalid{}} -> raise NotFoundError
      {:error, failure} -> raise failure
    end
  end

  defp key_position(%{"after" => keyset}) when is_binary(keyset), do: [after: keyset]
  defp key_position(%{"before" => keyset}) when is_binary(keyset), do: [before: keyset]
  defp key_position(params), do: if(paged?(params), do: raise(NotFoundError), else: [])

  @doc "Whether the address names a page of keys other than the first."
  def paged?(params), do: Map.has_key?(params, "after") or Map.has_key?(params, "before")

  @doc """
  A page reached by going forward always has one before it, and one reached by
  going back always has one after it.
  """
  def page_links(_fleet_id, %Ash.Page.Keyset{results: []}, _params),
    do: %{previous: nil, next: nil}

  def page_links(fleet_id, %Ash.Page.Keyset{results: keys, more?: more?}, params) do
    {previous?, next?} =
      case params do
        %{"after" => _keyset} -> {true, more?}
        %{"before" => _keyset} -> {more?, true}
        _first_page -> {false, more?}
      end

    # The map tab and its chosen key stay while the visitor pages through keys.
    kept = for name <- ["view", "key"], is_binary(params[name]), do: {name, params[name]}

    %{
      previous:
        if(previous?,
          do: fleet_page_path(fleet_id, [before: hd(keys).__metadata__.keyset], kept)
        ),
      next:
        if(next?,
          do: fleet_page_path(fleet_id, [after: List.last(keys).__metadata__.keyset], kept)
        )
    }
  end

  defp fleet_page_path(fleet_id, position, kept),
    do: "#{Keyfleet.Fleets.path(fleet_id)}?#{URI.encode_query(position ++ kept)}"

  @doc """
  A key's row of the list: its holder and its active shards as every page
  shares them (`Keyfleet.Agents.Here.labels_key/2`), each shard's agent with
  its name, picture and status label, or the shard's wallet while no agent has
  signed in with it.
  """
  def key_row(key, shards) do
    %{
      token_id: key.token_id,
      owner_wallet: key.owner_wallet,
      shards:
        for {wallet, name, avatar_url, label} <- shards do
          %{
            wallet: wallet,
            name: name,
            avatar_src: name && Avatar.shown(avatar_url, wallet),
            status_label: label
          }
        end
    }
  end

  @doc """
  The key numbers a list page holds, as `{first, last}`. The last page has
  no last number, since a key sold later joins it.
  """
  def listed(%Ash.Page.Keyset{results: []}, _pages), do: {1, nil}

  def listed(%Ash.Page.Keyset{results: keys}, %{next: next}),
    do: {hd(keys).token_id, if(next, do: List.last(keys).token_id)}

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
