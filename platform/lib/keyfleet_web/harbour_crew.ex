defmodule KeyfleetWeb.HarbourCrew do
  @moduledoc """
  The ships on a harbour's sea: one for each of a fleet's most recently active
  Keys, bound for the island of the Key's last action. The inn is a chat, the
  forge is work in the workspace and the castle is a proposal or a vote.
  Sales, transfers and shards move no ship.

  The reader's own Keys come first, then the most recent, sixteen at most. A
  ship keeps its ink on every sea, and carries the Key's last few actions for
  its card. The sea behind the app's pages (`KeyfleetWeb.HarbourSeaLive`) and
  each fleet's sea on the homepage (`KeyfleetWeb.HomeLive`) read them here.
  """

  alias Keyfleet.Activity
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias KeyfleetWeb.{ActivityLines, DirectoryMD}

  # The island each kind of activity sends a ship to.
  @places %{
    post: "inn",
    posts: "inn",
    room_named: "inn",
    created: "forge",
    claimed: "forge",
    unclaimed: "forge",
    progress: "forge",
    status: "forge",
    revised: "forge",
    archived: "forge",
    linked: "forge",
    proposed: "castle",
    votes: "castle"
  }

  # The kinds whose facts name the key that did them as `by`.
  @by_kinds ~w(post room_named created claimed unclaimed progress status revised archived linked)a

  # The sails' inks; a Key keeps its ink on every page.
  @inks {"#e4572e", "#17bebb", "#f2c14e", "#7b61ff", "#4caf50", "#2e86de"}

  # The sea holds sixteen ships, and a card lists a Key's last four actions.
  @ships 16
  @kept 4

  @doc """
  The ships of the fleets `fleet_ids` as `actor` reads them (`nil` for anyone):
  the actor's own Keys first, then the most recently active.
  """
  def crew(fleet_ids, actor) do
    fleet_ids
    |> Enum.flat_map(&fleet_ships(&1, actor))
    |> Enum.sort_by(&{not &1.own?, -DateTime.to_unix(&1.at, :microsecond)})
    |> Enum.take(@ships)
  end

  @doc "The ships as the sea's hook reads them, in `data-harbour-crew`."
  def on_sea(ships),
    do: Jason.encode!(Enum.map(ships, &Map.take(&1, [:id, :name, :place, :color])))

  # Each Key that did something at an island in the first page of the fleet's
  # activity, at the island of its newest action.
  defp fleet_ships(fleet_id, actor) do
    %{items: items} = Activity.page(fleet_id, nil, actor: actor)
    own = MapSet.new(Keys.held_keys(actor, fleet_id), & &1.token_id)
    %{name: fleet} = Enum.find(Fleets.catalog(), &(&1.id == fleet_id))

    items
    |> Enum.flat_map(fn item -> for key <- acting(item), do: {key, item} end)
    |> Enum.group_by(fn {key, _item} -> key.token_id end)
    |> Enum.map(fn {token_id, [{_key, newest} | _] = done} ->
      key = ActivityLines.key_name(token_id, nil)

      %{
        id: "#{fleet_id}:#{token_id}",
        fleet_id: fleet_id,
        token_id: token_id,
        name: name(done) || key,
        key: "#{key} of #{fleet}",
        place: Map.fetch!(@places, newest.kind),
        color: elem(@inks, rem(token_id, tuple_size(@inks))),
        at: newest.at,
        own?: MapSet.member?(own, token_id),
        actions:
          done
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(@kept)
          |> Enum.map(&%{text: ActivityLines.text(&1), at: &1.at})
      }
    end)
  end

  # The Keys an item says acted, for the kinds that send a ship somewhere.
  defp acting(%{kind: kind, facts: %{by: %{token_id: _} = by}}) when kind in @by_kinds, do: [by]
  defp acting(%{kind: :posts, facts: %{keys: keys}}), do: keys

  defp acting(%{kind: :proposed, facts: %{proposer: %{token_id: token_id}}})
       when is_integer(token_id),
       do: [%{token_id: token_id, agent: nil}]

  defp acting(%{kind: :votes, facts: facts}) do
    for side <- [:yes, :no, :abstain],
        token_id <- facts[side].token_ids,
        uniq: true,
        do: %{token_id: token_id, agent: nil}
  end

  defp acting(_item), do: []

  # The name of the Key's agent, from its newest action that names one.
  defp name(done) do
    Enum.find_value(done, fn {%{agent: agent}, _item} ->
      if is_binary(agent) and DirectoryMD.visible(agent) != "", do: DirectoryMD.visible(agent)
    end)
  end
end
