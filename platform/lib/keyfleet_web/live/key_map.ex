defmodule KeyfleetWeb.KeyMap do
  @moduledoc """
  What a fleet page's key map is told: every key's two marks when it loads,
  and the marks of the keys that have just changed after that.

  A key's marks are whether one of the viewer's wallets holds it and whether
  an agent runs it today. Someone signed out holds nothing. Owners are never
  sent to the map; the map draws every key sold and the rest of the level on
  sale, so how many are sold travels with the marks.
  """

  alias Keyfleet.Actors.Human
  alias Keyfleet.Keys

  # A change naming more keys than this is sent as a signal to load again,
  # which costs less than the change itself.
  @reset_above 2_000

  @doc """
  The map's first load: keys sold, the fleet's size (`nil` for a fleet whose
  levels keep opening), and the viewer's held keys and the keys agents run as
  `bitset/1`s.
  """
  def snapshot(fleet_id, %{total_minted: minted, max_supply: max_supply}, actor) do
    %{
      minted: minted,
      max_supply: max_supply,
      mine: bitset(held(fleet_id, actor, [])),
      agent: bitset(Enum.map(Keys.keys_run_in_fleet!(fleet_id), & &1.token_id))
    }
  end

  @doc """
  What the map is told once `token_ids` have changed: `{:patch, patch}` with
  each key's marks as `[token_id, flags]`, bit 0 held by the viewer and bit 1
  run by an agent, or `:reset` when more than #{@reset_above} keys changed.
  """
  def change(fleet_id, %{total_minted: minted}, token_ids, actor) do
    token_ids = token_ids |> Enum.uniq() |> Enum.sort()

    if length(token_ids) > @reset_above do
      :reset
    else
      only = [filter: [token_id: [in: token_ids]]]
      mine = MapSet.new(held(fleet_id, actor, only))

      agent =
        MapSet.new(Keys.keys_run_in_fleet!(fleet_id, query: only), & &1.token_id)

      {:patch,
       %{
         minted: minted,
         keys: for(id <- token_ids, do: [id, flag(mine, id, 1) + flag(agent, id, 2)])
       }}
    end
  end

  @doc """
  Whether key `token_id` can be chosen on the map: every key sold, and the
  next one on sale.
  """
  def choosable?(%{total_minted: minted, max_supply: max_supply}, token_id),
    do: is_integer(token_id) and token_id in 1..min(minted + 1, max_supply || minted + 1)//1

  @doc """
  The levels the map can go to, which are the levels it draws: each level
  with a key sold and the level of the next key on sale. Fleets without
  levels have none.
  """
  def levels(%{completed_levels: nil}), do: []
  def levels(%{completed_levels: completed}), do: Enum.to_list(1..(completed + 1))

  @doc """
  The keys numbered in `token_ids` as base64, over as many bytes as the
  highest of them needs: key `id` is bit `(id - 1) rem 8`, least significant
  first, of byte `(id - 1) div 8`.
  """
  def bitset(token_ids) do
    set = MapSet.new(token_ids)
    bytes = div(Enum.max(token_ids, fn -> 0 end) + 7, 8)

    # Each byte is written from its most significant bit down.
    bits =
      for byte <- 0..(bytes - 1)//1, bit <- 7..0//-1, into: <<>> do
        <<flag(set, byte * 8 + bit + 1, 1)::1>>
      end

    Base.encode64(bits)
  end

  defp held(fleet_id, %Human{wallet_addresses: [_ | _] = wallets} = actor, query) do
    fleet_id
    |> Keys.keys_held_in_fleet!(wallets, actor: actor, query: query)
    |> Enum.map(& &1.token_id)
  end

  defp held(_fleet_id, _actor, _query), do: []

  defp flag(set, id, value), do: if(MapSet.member?(set, id), do: value, else: 0)
end
