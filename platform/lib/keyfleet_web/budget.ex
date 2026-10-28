defmodule KeyfleetWeb.Budget do
  @moduledoc """
  Fits a read's answer into the bytes its caller can take (`max_bytes`),
  never cutting it silently: what is left out comes after the cursor the
  answer gives, so reading on from that cursor brings it.

  Posts and changes are kept in order, each part's from its start, and a
  part stops at the first that doesn't fit, so its cursor is the place of
  the last one kept. The bytes counted are the answer's JSON, with room to
  spare for each cursor that moves.
  """

  # A cursor that moves may take up to this many more bytes than the one it
  # replaces, and `has_more` or `cut` turning over one more.
  @slack 24

  @doc "The bytes `term` takes as JSON."
  def bytes(term), do: term |> Jason.encode_to_iodata!() |> IO.iodata_length()

  @doc """
  One page of posts, `messages`, fitted with the rest of its answer, `bare`
  (the answer with no posts), into `max_bytes`: `{:ok, kept, cut?}`, or
  `{:error, bytes}` when not even the first post fits, `bytes` being what it
  would take. `nil` keeps every post.
  """
  def page(_bare, messages, nil), do: {:ok, messages, false}

  def page(bare, messages, max_bytes) do
    left = max_bytes - bytes(bare) - @slack

    case prefix(messages, left) do
      {[], _left} when messages != [] -> {:error, max_bytes - left + cost(hd(messages))}
      {kept, _left} -> {:ok, kept, length(kept) < length(messages)}
    end
  end

  @doc """
  A sync's answer fitted into `max_bytes`, as `{:ok, answer}` with `cut`
  saying whether anything was left out, or `{:error, bytes}` when not even
  the first post or change waiting fits, `bytes` being what it would take,
  so a caller is never answered nothing over and over. The
  workspace's changes are kept first, then each room's posts and each wall's
  in the order they were named. `sent` holds the places the caller sent:
  `%{graph: seq, rooms: %{slug => seq}, keys: %{token_id => seq}}`.
  """
  def sync(answer, nil, _sent), do: {:ok, Map.put(answer, :cut, false)}

  def sync(answer, max_bytes, sent) do
    graph = answer.graph
    readable = Enum.reject(answer.rooms, &Map.has_key?(&1, :refused))

    bare =
      Map.merge(answer, %{
        graph: graph(graph, [], sent.graph),
        rooms: Enum.map(answer.rooms, &bare(&1, sent.rooms)),
        keys: Enum.map(answer.keys, &bare(&1, sent.keys)),
        cut: false
      })

    parts = 1 + length(readable) + length(answer.keys)
    left = max_bytes - bytes(bare) - @slack * parts

    {events, left_after} = prefix(graph.events, left)
    {rooms, left_after} = Enum.map_reduce(answer.rooms, left_after, &fit(&1, &2, sent.rooms))
    {keys, _left} = Enum.map_reduce(answer.keys, left_after, &fit(&1, &2, sent.keys))
    waiting = graph.events ++ Enum.flat_map(answer.rooms ++ answer.keys, &Map.get(&1, :messages, []))
    kept = events ++ Enum.flat_map(rooms ++ keys, &Map.get(&1, :messages, []))

    if left < 0 or (kept == [] and waiting != []) do
      {:error, max_bytes - left + Enum.sum(Enum.map(Enum.take(waiting, 1), &cost/1))}
    else
      {:ok,
       Map.merge(answer, %{
         graph: graph(graph, events, sent.graph),
         rooms: rooms,
         keys: keys,
         cut: length(kept) < length(waiting)
       })}
    end
  end

  # The workspace's part with the changes kept: unchanged when all are, and
  # otherwise read on from the last one kept.
  defp graph(%{events: events} = graph, events, _sent), do: graph

  defp graph(graph, kept, sent),
    do: %{graph | events: kept, next_cursor: last_seq(kept, sent), has_more: true}

  defp bare(%{refused: _refused} = room, _sent), do: room
  defp bare(part, sent), do: %{part | messages: [], cursor: sent_place(part, sent)}

  defp fit(%{refused: _refused} = room, left, _sent), do: {room, left}

  defp fit(%{messages: messages} = part, left, sent) do
    case prefix(messages, left) do
      {^messages, left} -> {part, left}
      {kept, left} -> {%{part | messages: kept, cursor: last_seq(kept, sent_place(part, sent))}, left}
    end
  end

  defp sent_place(%{slug: slug}, sent), do: Map.fetch!(sent, slug)
  defp sent_place(%{token_id: token_id}, sent), do: Map.fetch!(sent, token_id)

  defp last_seq([], sent), do: sent
  defp last_seq(kept, _sent), do: List.last(kept).seq

  # The first of `items` that fit in `left` bytes, each costing its JSON and
  # the comma before it, and the bytes left; none is kept after the first
  # that doesn't fit.
  defp prefix(items, left) do
    {kept, left} =
      Enum.reduce_while(items, {[], left}, fn item, {kept, left} ->
        cost = cost(item)
        if cost <= left, do: {:cont, {[item | kept], left - cost}}, else: {:halt, {kept, left}}
      end)

    {Enum.reverse(kept), left}
  end

  defp cost(item), do: bytes(item) + 1
end
