defmodule KeyfleetWeb.HarbourCrew do
  @moduledoc """
  The ships on a harbour's sea: one for each of a fleet's most recently active
  Keys, bound for the island of the Key's last action. The inn is a chat, the
  forge is work in the workspace and the castle is a proposal or a vote.
  Sales, transfers and shards move no ship.

  The reader's own Keys come first, then the most recent, sixteen at most. A
  ship keeps its ink on every sea, and carries the Key's last few actions for
  its card. The sea behind the app's pages (`KeyfleetWeb.HarbourSeaLive`) and
  the homepage's seas (`KeyfleetWeb.HomeLive`) draw them here from each fleet's
  activity: as anyone reads it, from the one reading every open page shares
  (`KeyfleetWeb.FleetNow`), or as a member reads it.
  """

  alias Keyfleet.Fleets
  alias KeyfleetWeb.{ActivityLines, DirectoryMD}

  # The island each kind of activity sends a ship to.
  @places %{
    post: "inn",
    posts: "inn",
    room_named: "inn",
    created: "forge",
    tasks: "forge",
    claimed: "forge",
    unclaimed: "forge",
    submitted: "forge",
    progress: "forge",
    reviewed: "forge",
    status: "forge",
    revised: "forge",
    joined: "forge",
    left: "forge",
    archived: "forge",
    changes: "forge",
    linked: "forge",
    proposed: "castle",
    votes: "castle"
  }

  # The kinds whose facts name the key that did them as `by`.
  @by_kinds ~w(post room_named created tasks claimed unclaimed submitted progress reviewed status revised joined left archived changes linked)a

  # The sails' inks; a Key keeps its ink on every page.
  @inks {"#e4572e", "#17bebb", "#f2c14e", "#7b61ff", "#4caf50", "#2e86de"}

  # The sea holds sixteen ships, and a card lists a Key's last four actions.
  @ships 16
  @kept 4

  @doc """
  The ships that make the sea out of `ships`, each marked `own?`: the reader's
  own Keys first, then the most recently active, sixteen at most.
  """
  def sea(ships) do
    ships
    |> Enum.sort_by(&{not &1.own?, -DateTime.to_unix(&1.at, :microsecond)})
    |> Enum.take(@ships)
  end

  @doc "The ships as the sea's hook reads them, in `data-harbour-crew`."
  def on_sea(ships),
    do: Jason.encode!(Enum.map(ships, &Map.take(&1, [:id, :name, :place, :color])))

  @doc """
  A ship for each Key that did something at an island in `items`, the first
  page of the fleet's activity, at the island of its newest action.
  """
  def ships(fleet_id, items) do
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
