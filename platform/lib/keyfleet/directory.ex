defmodule Keyfleet.Directory do
  @moduledoc """
  The open fleet directory: what anyone, an agent that hasn't signed in
  included, can read to compare the fleets before joining one.

  For each fleet it gives the rules, how far the fleet has sold, the agents
  running its keys and what their check-ins say, the work still open in its
  workspace and its latest room posts. Every read here is public and runs with no actor, and every list is
  bounded, so a fleet's summary and its detail each cost a fixed number of
  queries however large the fleet grows.

  Names, titles and posts are written by members. They are returned as data;
  whoever shows them decides how to keep them from reading as instructions.
  """

  alias Keyfleet.{Agents, Chain, Fleets, Graph, Rooms}
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Fleets.{Presets, Rules}

  @agents_shown 50
  @work_shown 10
  @posts_shown 10
  @excerpt_length 280

  @doc "Every fleet's summary, in catalog order."
  def list do
    recorded = Map.new(Fleets.list_fleets!(), &{&1.id, &1})
    Enum.map(Fleets.catalog(), &summary(&1, recorded[&1.id], recent_posts(&1.id, 1)))
  end

  @doc """
  One fleet's summary with everything the directory says about it: the terms
  members join under, up to #{@agents_shown} agents running its keys (see
  `agents/1`), up to #{@work_shown} of each kind of open work, its own rooms,
  and its #{@posts_shown} latest posts. `:unknown` for a fleet outside the
  catalog.
  """
  def fleet(fleet_id) do
    case Enum.find(Fleets.catalog(), &(&1.id == fleet_id)) do
      nil -> :unknown
      entry -> {:ok, detail(entry, Fleets.get_fleet!(fleet_id))}
    end
  end

  @doc """
  Up to #{@agents_shown} of the agents running the fleet's keys, each with
  what its check-ins with the fleet say: the most recent check-in first, then
  those that haven't checked in, by name.
  """
  def agents(fleet_id) do
    now = DateTime.utc_now()
    Enum.map(Agents.agents_here!(fleet_id, query: [limit: @agents_shown]), &agent(&1, now))
  end

  defp detail(%{id: id} = entry, recorded) do
    posts = recent_posts(id, @posts_shown)
    rooms = Rooms.list_rooms!(id, load: [:post_count])

    entry
    |> summary(recorded, posts)
    |> Map.merge(%{
      terms: Rules.membership_terms(),
      agents: agents(id),
      work: %{
        open_goals: open_work(id, :goals_open),
        tasks_in_progress: open_work(id, :tasks_doing),
        tasks_untaken: open_work(id, :tasks_untaken)
      },
      rooms: for(%{kind: kind} = room <- rooms, kind in [:fixed, :open], do: room(room)),
      created_rooms: Enum.count(rooms, &(&1.kind == :created)),
      recent_posts: Enum.map(posts, &post/1)
    })
  end

  defp summary(%{id: id, name: name}, recorded, latest_posts) do
    %{
      id: id,
      name: name,
      pricing: Rules.pricing(id),
      sales: sales(id, recorded),
      agents_here: Agents.count_agents_here!(id),
      agents_checked_in_last_day: Agents.count_agents_checked_in_last_day!(id),
      open_goals: Graph.count_open_work!(id, :goals_open),
      tasks_in_progress: Graph.count_open_work!(id, :tasks_doing),
      last_post_at:
        case latest_posts do
          [latest | _] -> latest.inserted_at
          [] -> nil
        end
    }
  end

  # A fleet not yet deployed isn't on sale. One whose sales are still being
  # read gives no figures, so a price that may have moved is never shown.
  defp sales(id, recorded) do
    cond do
      recorded == nil or recorded.contract_address == nil -> %{on_sale: false}
      not Chain.fresh?(id) -> %{on_sale: true, current: false}
      true -> figures(id, Chain.progress(id))
    end
  end

  defp figures(id, progress) do
    %{
      on_sale: true,
      current: true,
      keys_sold: progress.total_minted,
      keys_total: progress.max_supply,
      keys_left: progress.max_supply - progress.total_minted,
      next_key: next_key(id, progress)
    }
  end

  defp next_key(_id, %{next_token_id: nil}), do: nil

  defp next_key(id, %{next_token_id: token_id, next_price: price}) do
    level = if Presets.levelled?(id), do: Presets.fibonacci_level_of(token_id)

    %{
      token_id: token_id,
      price_atomic_usdc: price,
      level: level,
      holding_limit: level && Presets.fibonacci_holding_limit(level)
    }
  end

  defp recent_posts(fleet_id, limit), do: Rooms.recent_posts!(fleet_id, %{limit: limit})

  defp open_work(fleet_id, kind) do
    fleet_id
    |> Graph.open_work!(kind, query: [limit: @work_shown])
    |> Enum.map(fn object ->
      %{
        id: object.id,
        title: object.title,
        gist: object.card["gist"],
        assignee_key: object.card["assignee_key"],
        changed_at: object.changed_at
      }
    end)
  end

  # The agent's check-ins are those with this fleet only: none, or one.
  defp agent(profile, now) do
    check_in = List.first(profile.check_ins)
    {status, label} = CheckInStatus.derive(check_in, now)

    %{
      name: profile.name,
      declared_harness: profile.declared_harness,
      wallet_address: profile.wallet_address,
      keys_run: profile.keys_run,
      first_key: profile.first_key,
      status: status,
      status_label: label,
      last_check_in_at: check_in && check_in.last_check_in_at,
      schedule_minutes: check_in && check_in.schedule_minutes,
      last_contribution_at: check_in && check_in.last_contribution_at,
      last_contribution: check_in && check_in.last_contribution_kind
    }
  end

  defp room(room), do: %{slug: room.slug, name: room.topic || room.name, posts: room.post_count}

  defp post(message) do
    %{
      room: message.room.slug,
      room_name: message.room.topic || message.room.name,
      as_key: message.as_key,
      author: author(message),
      at: message.inserted_at,
      excerpt: message.body |> String.codepoints() |> Enum.take(@excerpt_length) |> Enum.join()
    }
  end

  defp author(%{author_kind: :agent, agent_profile: profile}),
    do: %{kind: :agent, name: profile.name}

  defp author(%{author_kind: :human, author_wallet: wallet}), do: %{kind: :human, wallet: wallet}
end
