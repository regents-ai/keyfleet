defmodule Keyfleet.Graph.Workspace.Read do
  @moduledoc """
  Answers a workspace read from the fleet's read tables, never from its
  writer, so a read never waits behind a write.

  Each read is answered from one read-only snapshot of the tables, so it
  shows the workspace exactly as it stood at `watermark`, the place in the
  fleet's log the tables had reached: a write whose `head_seq` is at or below
  it is in the answer, and nothing past it is.

  `get` answers one object, with where a submitted task's review stands
  (`review`), the Key it belongs to (`owner_key`), and a page of up to 200 of
  its links, oldest first, made after `relations_after`;
  `relations_next_cursor` is the `relations_after` to read the next page
  from, or nil after the last one. `linked` names the item at the other end
  of each of those links by id, with its type, title, standing and whether it
  is archived, so a task's goal, what it depends on and what it produced read
  with it. A task also answers `rerun_check` (`Keyfleet.Graph.RerunCheck`):
  whether it carries everything a rerun needs, and what it is missing. `changes` answers the copied
  events after `after_seq`, the whole fleet's or, given `project`, those that
  touched that project, oldest first, at most `limit` of them and no more
  than 512 KiB of them unless one event alone is larger;
  `next_cursor` is the `after_seq` to read on from, and `run_id` names the
  log they come from. Given `object`, it answers that object's own changes
  alone: its creation, edits, archiving, links and their removal. Given
  `max_bytes`, a page holds no more than that, and a change larger than it
  alone is refused with its size rather than answered past the budget.
  `graph` answers the items its graph draws, the 120 most recently changed,
  the whole fleet's or one project's, type's or owner's, or one goal's map
  (the `:graph` read of objects), with the archived ones only when asked for: each with its type, title, project, standing,
  owner and when it last changed. Beside them the links between them, oldest
  first, at most 600; `more_nodes` and `more_edges` say whether any were left
  out, and `owners` counts the items each Key owns among them.

  `get` and `changes` name, in `agents`, the agents behind what they
  answer, by wallet: the agent that created the object, or that made each
  change, with the name it gave itself, as the fleet's pages show it beside
  the Key. A goal's agents include each agent that joined it.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Agents
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Event
  alias Keyfleet.Graph.RerunCheck

  @relation_page 200
  @graph_nodes 120
  @graph_edges 600

  @impl true
  def run(input, opts, context) do
    kind = Keyword.fetch!(opts, :read)
    Graph.in_snapshot(fn -> read(kind, input.arguments, Ash.Context.to_opts(context)) end)
  end

  defp read(:get, %{fleet_id: fleet_id, id: id, relations_after: after_seq}, opts) do
    {_run_id, watermark} = standing(fleet_id, opts)

    case Graph.read_object!(fleet_id, id, [load: [:review, :owner_key]] ++ opts) do
      nil ->
        {:error,
         RefusedError.exception(code: "not_found", reason: "no such object", details: %{id: id})}

      object ->
        {page, rest} =
          fleet_id
          |> Graph.read_relations_touching!(id, after_seq, @relation_page + 1, opts)
          |> Enum.split(@relation_page)

        %{
          object: Map.take(object, [:id, :type, :data, :sys, :version, :review]),
          owner_key: object.owner_key,
          relations: Enum.map(page, &Map.take(&1, [:id, :type, :source, :target, :data])),
          relations_next_cursor: if(rest != [], do: List.last(page).created_seq),
          linked: linked(fleet_id, id, page, opts),
          rerun_check: rerun_check(object),
          watermark: watermark,
          agents:
            Agents.names_by_wallet([
              agent_wallet(object.sys["created_by"])
              | object.sys |> Map.get("joined", []) |> Enum.map(&agent_wallet/1)
            ])
        }
    end
  end

  defp read(:changes, %{fleet_id: fleet_id, after_seq: after_seq} = args, opts) do
    {run_id, watermark} = standing(fleet_id, opts)

    with {:ok, events, has_more} <- events(args, opts) do
      page = Enum.map(events, &Event.view/1)

      %{
        run_id: run_id,
        events: page,
        next_cursor: if(has_more, do: List.last(page).seq, else: max(after_seq, watermark)),
        has_more: has_more,
        watermark: watermark,
        agents: page |> Enum.map(&writer(&1.actor)) |> Agents.names_by_wallet()
      }
    end
  end

  defp read(:graph, %{fleet_id: fleet_id} = args, opts) do
    {_run_id, watermark} = standing(fleet_id, opts)
    filter = Map.take(args, [:project, :type, :owner_key, :goal, :archived])

    {nodes, more_nodes} =
      fleet_id
      |> Graph.graph_objects!(filter, [query: [limit: @graph_nodes + 1]] ++ opts)
      |> Enum.split(@graph_nodes)

    {edges, more_edges} =
      case nodes do
        [] ->
          {[], []}

        nodes ->
          fleet_id
          |> Graph.relations_among!(
            Enum.map(nodes, & &1.id),
            [query: [limit: @graph_edges + 1]] ++ opts
          )
          |> Enum.split(@graph_edges)
      end

    %{
      nodes: Enum.map(nodes, &graph_node/1),
      edges: Enum.map(edges, &Map.take(&1, [:id, :type, :source, :target])),
      owners: owners(nodes),
      more_nodes: more_nodes != [],
      more_edges: more_edges != [],
      watermark: watermark
    }
  end

  defp graph_node(object) do
    %{
      id: object.id,
      type: object.type,
      title: object.title,
      project: object.project,
      standing: object.standing,
      owner_key: object.owner_key,
      archived: object.sys["archived"] == true,
      changed_at: object.changed_at
    }
  end

  # Each Key that owns any of the items, lowest first, with how many it owns.
  defp owners(nodes) do
    nodes
    |> Enum.map(& &1.owner_key)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.map(fn {key, items} -> %{key: key, items: items} end)
  end

  # One object's changes: a page of them, cut to `max_bytes` here, as the
  # database cuts a page of the fleet's.
  defp events(%{object: id} = args, opts) when is_binary(id) do
    budget = args[:max_bytes] || Event.page_bytes()

    {events, rest} =
      args.fleet_id
      |> Graph.object_events!(id, args.after_seq, args.limit + 1, opts)
      |> Enum.split(args.limit)

    {page, cut} = within(events, budget)
    fitted(page, args[:max_bytes], cut ++ rest != [])
  end

  defp events(%{fleet_id: fleet_id, after_seq: after_seq, limit: limit} = args, opts) do
    window = args |> Map.take([:project, :max_bytes]) |> Map.reject(&is_nil(elem(&1, 1)))
    project = %{project: args[:project]}
    page = Graph.read_events!(fleet_id, after_seq, limit, window, opts)
    has_more = page != [] and more_after?(fleet_id, List.last(page).seq, project, opts)
    fitted(page, args[:max_bytes], has_more)
  end

  # The first events that fit in `budget` bytes together, and the rest; the
  # first alone when it doesn't fit, so a page without a caller's budget is
  # never empty.
  defp within(events, budget) do
    {page, rest, _left} =
      Enum.reduce(events, {[], [], budget}, fn
        event, {[], [], left} ->
          {[event], [], left - event.byte_size}

        %{byte_size: bytes} = event, {page, [], left} when bytes <= left ->
          {[event | page], [], left - bytes}

        event, {page, rest, left} ->
          {page, [event | rest], left}
      end)

    {Enum.reverse(page), Enum.reverse(rest)}
  end

  # A budget the caller named is never broken: a change larger than it alone
  # is refused with its size, and the caller chooses to raise the budget.
  defp fitted([%{byte_size: bytes, seq: seq} | _rest], max_bytes, _has_more)
       when is_integer(max_bytes) and bytes > max_bytes,
       do:
         {:error,
          RefusedError.exception(
            code: "over_budget",
            reason: "the change at seq #{seq} alone is #{bytes} bytes, more than max_bytes",
            details: %{seq: seq, bytes: bytes}
          )}

  defp fitted(page, _max_bytes, has_more), do: {:ok, page, has_more}

  # The item at the other end of each link on the page, by id, with what a
  # reader needs to judge it without reading it: its type, title, standing
  # and whether it is archived.
  defp linked(_fleet_id, _id, [], _opts), do: %{}

  defp linked(fleet_id, id, page, opts) do
    ids = page |> Enum.map(&if(&1.source == id, do: &1.target, else: &1.source)) |> Enum.uniq()

    fleet_id
    |> Graph.object_titles!(ids, [load: [:standing]] ++ opts)
    |> Map.new(fn other ->
      {other.id,
       %{
         type: other.type,
         title: other.title,
         standing: other.standing,
         archived: other.sys["archived"] == true
       }}
    end)
  end

  defp rerun_check(%{type: "task", data: data}) do
    missing = RerunCheck.missing(data)
    %{ready: missing == [], missing: missing}
  end

  defp rerun_check(_object), do: nil

  defp agent_wallet(%{"kind" => "agent", "wallet" => wallet}), do: wallet
  defp agent_wallet(_person), do: nil

  defp writer(actor) do
    case Event.member(actor) do
      {_token_id, "agent", wallet} -> wallet
      _person_or_workspace -> nil
    end
  end

  # A fleet whose log has never been copied reads as an empty log.
  defp standing(fleet_id, opts) do
    case Graph.get_cursor!(fleet_id, opts) do
      nil -> {nil, 0}
      cursor -> {cursor.run_id, cursor.applied_seq}
    end
  end

  defp more_after?(fleet_id, seq, project, opts) do
    Event
    |> Ash.Query.for_read(
      :page,
      Map.merge(project, %{fleet_id: fleet_id, after_seq: seq, limit: 1}),
      opts
    )
    |> Ash.exists?(opts)
  end
end
