defmodule KeyfleetWeb.FleetPage do
  @moduledoc """
  What a fleet's page reads: the key on offer, a page of its keys with the
  agents running them, the links to the pages either side, the key the map
  has chosen, and "What's happening" with what the fleet is trying now.

  A page name that isn't one the keys can answer is a page that doesn't exist.
  """

  alias Keyfleet.Activity
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.KeyMap
  alias KeyfleetWeb.NotFoundError

  @doc "The key on offer now, which moves on with every sale."
  def next_sale(fleet_id, progress) do
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

    # The map keeps its chosen key while the visitor pages through keys.
    kept = for name <- ["key"], is_binary(params[name]), do: {name, params[name]}

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
    do: "/app/fleets/#{fleet_id}?#{URI.encode_query(position ++ kept)}"

  @doc """
  Each key with the agent running it, if any, and what that agent's
  check-ins with the fleet say.
  """
  def fleet_keys(fleet_id, keys, actor) do
    pairings = Keys.fleet_operators!(fleet_id, Enum.map(keys, & &1.token_id), actor: actor)

    check_ins =
      Map.new(
        Agents.check_ins_in_fleet!(fleet_id, Enum.map(pairings, & &1.agent_profile.id)),
        &{&1.agent_profile_id, &1}
      )

    now = DateTime.utc_now()

    operators =
      Map.new(pairings, fn %{agent_profile: agent} = pairing ->
        {_status, label} = CheckInStatus.derive(check_ins[agent.id], now)
        {pairing.token_id, %{name: agent.name, status_label: label}}
      end)

    for key <- keys do
      %{
        token_id: key.token_id,
        owner_wallet: key.owner_wallet,
        operator: operators[key.token_id]
      }
    end
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
  "Trying now", at the top of "What's happening": the fleet's open goals and
  the work on them, with the agent running each key on a task named.
  """
  def read_trying_now(fleet_id) do
    now = Graph.trying_now(fleet_id)
    tasks = Enum.flat_map(now.goals, & &1.tasks) ++ now.taken
    token_ids = for %{assignee_key: token_id} <- tasks, token_id, uniq: true, do: token_id
    ActivityLines.trying_now(now, agents(fleet_id, token_ids))
  end

  # The agent running each of these keys, by number; none to look up when no
  # key is shown.
  defp agents(_fleet_id, []), do: %{}

  defp agents(fleet_id, token_ids) do
    fleet_id
    |> Keys.fleet_operators!(token_ids)
    |> Map.new(&{&1.token_id, &1.agent_profile.name})
  end

  @doc """
  The first `wanted` pages of "What's happening", newest first, as the items,
  the cursor for the page after them and how many pages were read.
  """
  def activity_pages(fleet_id, wanted), do: activity_pages(fleet_id, nil, wanted, [])

  defp activity_pages(fleet_id, cursor, wanted, read) do
    %{items: items, cursor: next} = Activity.page(fleet_id, cursor)
    read = [items | read]

    if next != nil and length(read) < wanted,
      do: activity_pages(fleet_id, next, wanted, read),
      else: {read |> Enum.reverse() |> Enum.concat(), next, length(read)}
  end
end
