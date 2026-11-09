defmodule KeyfleetWeb.WorkspaceGraph do
  @moduledoc """
  Lays out the workspace's graph, as `Keyfleet.Graph.Workspace` reads it
  (its `graph` action), for the Graph view of a workspace's Project, and
  one goal's map as a tree for the goal's page (`tree/2`).

  Items stand in columns by the way work flows: goals, then the tasks and
  services that deliver on them, then what the work found (evidence,
  findings and reviews), then notes and dead ends. A column of more than
  twelve items wraps into several. Within a column each item sits as near as
  it can to the items it links to in the column before it, so most links run
  short and level. Every place is worked out here, in whole points of the
  picture, so the page draws it with no script at all; links run from the
  right of the item they leave to the left of the one they reach, or round
  the right side when both stand in one column.

  Each item is coloured by its standing (`tone/1`): open, in progress,
  submitted or awaiting review, held up (blocked or disputed), done (accepted,
  reproduced or achieved) or dropped. Items with no standing, such as findings, are
  drawn plain.
  """

  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.WorkspacePage

  @columns [~w(goal), ~w(task service), ~w(evidence finding review), ~w(note dead_end)]
  @rows 12

  @node_width 256
  @node_height 56
  @row_pitch 72
  # How far each item's card is cut at two opposite corners.
  @cut 8
  @wrap_gap 24
  @column_gap 72

  # The longest title an item shows in the picture; its full title is in the
  # list under it and in its own page.
  @title_shown 32

  @tones %{
    "open" => :open,
    "todo" => :open,
    "doing" => :doing,
    "done" => :waiting,
    "awaiting_review" => :waiting,
    "blocked" => :held,
    "disputed" => :held,
    "accepted" => :done,
    "reproduced" => :done,
    "achieved" => :done,
    "dropped" => :dropped
  }

  @tone_names [
    open: "Open",
    doing: "In progress",
    waiting: "Awaiting review",
    held: "Blocked or disputed",
    done: "Done",
    dropped: "Dropped",
    plain: "No status"
  ]

  @standing_names %{
    "open" => "Open",
    "todo" => "To do",
    "doing" => "In progress",
    "done" => "Submitted",
    "awaiting_review" => "Awaiting review",
    "blocked" => "Blocked",
    "disputed" => "Disputed",
    "accepted" => "Accepted",
    "reproduced" => "Reproduced",
    "achieved" => "Achieved",
    "dropped" => "Dropped"
  }

  @doc """
  The picture and the list of `graph`: each item with its place, its tone and
  the address of its page; each link with the path it runs along; the tones
  in use, for the key; each item's links in words, for the list; and when
  the most recently changed item changed (`newest`), nil for none.
  `labels` names each project by its title in the whole fleet's view.
  """
  def draw(graph, fleet_id, labels) do
    placed = place(graph.nodes, graph.edges)
    by_id = Map.new(placed, &{&1.id, &1})

    nodes = Enum.map(placed, &node(&1, fleet_id, labels))
    edges = for edge <- graph.edges, do: edge(edge, by_id)

    %{
      width: width(placed),
      height: height(placed),
      nodes: nodes,
      edges: edges,
      tones: tones(nodes),
      owners: graph.owners,
      rows: rows(nodes, graph.edges, Map.new(nodes, &{&1.id, &1})),
      more_nodes?: graph.more_nodes,
      more_edges?: graph.more_edges,
      newest: newest(graph.nodes)
    }
  end

  @doc """
  One goal's map as a tree, for the goal's page, from what `draw/3` drew of
  it: the items linked to the goal, each with the items linked to it in
  turn. Every item stands once, under the first item that reaches it along
  the links, nearest the goal first and the oldest link first. Each says by
  which kind of link it hangs from the one above it (`via`). Items no link
  joins to the goal follow at the top, so none is left out. The goal itself
  is the page, so it is not in the tree.
  """
  def tree(%{nodes: nodes, edges: edges}, goal) do
    by_id = Map.new(nodes, &{&1.id, &1})

    around =
      edges
      |> Enum.reduce(%{}, fn %{source: source, target: target, type: type}, around ->
        around
        |> Map.update(source, [{target, type}], &[{target, type} | &1])
        |> Map.update(target, [{source, type}], &[{source, type} | &1])
      end)
      |> Map.new(fn {id, links} -> {id, Enum.reverse(links)} end)

    {children, seen} = grow([goal], MapSet.new([goal]), %{}, around)

    {loose, children, _seen} =
      Enum.reduce(nodes, {[], children, seen}, fn node, {loose, children, seen} ->
        if MapSet.member?(seen, node.id) do
          {loose, children, seen}
        else
          {children, seen} = grow([node.id], MapSet.put(seen, node.id), children, around)
          {[{node.id, nil} | loose], children, seen}
        end
      end)

    branch(under(children, goal) ++ Enum.reverse(loose), children, by_id)
  end

  # One step out from the items reached last, to the items not yet reached.
  defp grow([], seen, children, _around), do: {children, seen}

  defp grow(frontier, seen, children, around) do
    {next, seen, children} =
      for id <- frontier,
          {other, type} <- Map.get(around, id, []),
          reduce: {[], seen, children} do
        {next, seen, children} ->
          if MapSet.member?(seen, other),
            do: {next, seen, children},
            else:
              {[other | next], MapSet.put(seen, other),
               Map.update(children, id, [{other, type}], &[{other, type} | &1])}
      end

    grow(Enum.reverse(next), seen, children, around)
  end

  defp under(children, id), do: children |> Map.get(id, []) |> Enum.reverse()

  defp branch(entries, children, by_id) do
    for {id, via} <- entries,
        do: %{
          item: Map.fetch!(by_id, id),
          via: via,
          branch: branch(under(children, id), children, by_id)
        }
  end

  # The read answers each item's change as an ISO 8601 time.
  defp newest(nodes) do
    nodes
    |> Enum.map(fn %{changed_at: at} ->
      {:ok, at, _offset} = DateTime.from_iso8601(at)
      at
    end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc "The tone an item is drawn in, by its standing."
  def tone(standing), do: Map.get(@tones, standing, :plain)

  @doc "The name of a tone, as the key under the picture shows it."
  def tone_name(tone), do: Keyword.fetch!(@tone_names, tone)

  # Columns first, then each column's order, then each item's point.
  defp place(nodes, edges) do
    neighbours = neighbours(edges)

    @columns
    |> Enum.map(fn types -> Enum.filter(nodes, &(&1.type in types)) end)
    |> Enum.reject(&(&1 == []))
    |> order(neighbours)
    |> points()
  end

  defp neighbours(edges) do
    Enum.reduce(edges, %{}, fn %{source: source, target: target}, around ->
      around
      |> Map.update(source, [target], &[target | &1])
      |> Map.update(target, [source], &[source | &1])
    end)
  end

  # The first column keeps the order the read gave it, the most recently
  # changed first. Each column after it is sorted by the mean row of the
  # items each of its items links to in the columns before it; one linked to
  # none of them keeps its place after those that are.
  defp order([first | rest], neighbours) do
    {columns, _rows} =
      Enum.reduce(rest, {[first], rows_of(first)}, fn column, {done, rows} ->
        sorted =
          column
          |> Enum.with_index()
          |> Enum.sort_by(fn {node, index} -> {mean_row(node, neighbours, rows), index} end)
          |> Enum.map(&elem(&1, 0))

        {[sorted | done], Map.merge(rows, rows_of(sorted))}
      end)

    Enum.reverse(columns)
  end

  defp order([], _neighbours), do: []

  defp rows_of(column),
    do:
      column |> Enum.with_index() |> Map.new(fn {node, index} -> {node.id, rem(index, @rows)} end)

  defp mean_row(node, neighbours, rows) do
    case for(id <- Map.get(neighbours, node.id, []), row = rows[id], do: row) do
      [] -> @rows
      seen -> Enum.sum(seen) / length(seen)
    end
  end

  # Each column wraps every twelve items; columns stand further apart than
  # the wraps of one column.
  defp points(columns) do
    {placed, _x} =
      Enum.reduce(columns, {[], 0}, fn column, {placed, x} ->
        wraps = div(length(column) + @rows - 1, @rows)

        at =
          column
          |> Enum.with_index()
          |> Enum.map(fn {node, index} ->
            Map.merge(node, %{
              x: x + div(index, @rows) * (@node_width + @wrap_gap),
              y: rem(index, @rows) * @row_pitch
            })
          end)

        {placed ++ at, x + wraps * (@node_width + @wrap_gap) - @wrap_gap + @column_gap}
      end)

    placed
  end

  defp width([]), do: 0
  defp width(placed), do: placed |> Enum.map(& &1.x) |> Enum.max() |> Kernel.+(@node_width)

  defp height([]), do: 0
  defp height(placed), do: placed |> Enum.map(& &1.y) |> Enum.max() |> Kernel.+(@node_height)

  defp node(node, fleet_id, labels) do
    {kind, _plural} = WorkspacePage.type_name(node.type)
    tone = tone(node.standing)

    %{
      id: node.id,
      x: node.x,
      y: node.y,
      width: @node_width,
      height: @node_height,
      type: node.type,
      kind: String.capitalize(kind),
      title: node.title,
      shown_title: shorten(node.title),
      # A card cut at its top left and bottom right corners, as the site's
      # panels are.
      shape:
        "M #{node.x + @cut} #{node.y} H #{node.x + @node_width} V #{node.y + @node_height - @cut} " <>
          "L #{node.x + @node_width - @cut} #{node.y + @node_height} H #{node.x} V #{node.y + @cut} Z",
      tone: tone,
      standing: Map.get(@standing_names, node.standing),
      owner_key: node.owner_key,
      owner: node.owner_key && ActivityLines.key_name(node.owner_key, nil),
      project: labels[node.project],
      archived?: node.archived,
      path: WorkspacePage.item_path(fleet_id, node.id)
    }
  end

  defp shorten(nil), do: ""

  defp shorten(title) do
    if String.length(title) > @title_shown,
      do: String.slice(title, 0, @title_shown - 1) <> "…",
      else: title
  end

  # A link leaves the middle of its source's right side and reaches the
  # middle of its target's left side, or the other way round when it runs
  # back; between two items of one column it bows out to the right, never
  # past the gap before the next column. `curve` is its four points, start,
  # two handles and end, which the page's script hands the GPU.
  defp edge(edge, by_id) do
    from = Map.fetch!(by_id, edge.source)
    to = Map.fetch!(by_id, edge.target)
    y1 = from.y + div(@node_height, 2)
    y2 = to.y + div(@node_height, 2)

    points =
      cond do
        from.x == to.x ->
          x = from.x + @node_width
          bow = x + min(div(@column_gap, 2) + div(abs(y2 - y1), 8), @column_gap)
          [x, y1, bow, y1, bow, y2, x, y2]

        from.x < to.x ->
          {x1, x2} = {from.x + @node_width, to.x}
          bend = div(x2 - x1, 2)
          [x1, y1, x1 + bend, y1, x2 - bend, y2, x2, y2]

        true ->
          {x1, x2} = {from.x, to.x + @node_width}
          bend = div(x1 - x2, 2)
          [x1, y1, x1 - bend, y1, x2 + bend, y2, x2, y2]
      end

    [x1, y1, c1x, c1y, c2x, c2y, x2, y2] = points

    %{
      id: edge.id,
      type: edge.type,
      source: edge.source,
      target: edge.target,
      path: "M #{x1} #{y1} C #{c1x} #{c1y}, #{c2x} #{c2y}, #{x2} #{y2}",
      curve: Enum.join(points, " ")
    }
  end

  defp tones(nodes) do
    counts = Enum.frequencies_by(nodes, & &1.tone)

    for {tone, name} <- @tone_names,
        count = counts[tone],
        do: %{tone: tone, name: name, count: count}
  end

  # The list under the picture: every item, in the picture's order, with
  # each of its links in words, as its own page says them.
  defp rows(nodes, edges, by_id) do
    links =
      Enum.reduce(edges, %{}, fn edge, links ->
        relation = WorkspacePage.relation_words(edge.type)

        links
        |> Map.update(
          edge.source,
          [{:to, relation, by_id[edge.target]}],
          &[{:to, relation, by_id[edge.target]} | &1]
        )
        |> Map.update(
          edge.target,
          [{:from, relation, by_id[edge.source]}],
          &[{:from, relation, by_id[edge.source]} | &1]
        )
      end)

    for node <- nodes, do: Map.put(node, :links, Enum.reverse(Map.get(links, node.id, [])))
  end
end
