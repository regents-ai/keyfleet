defmodule Keyfleet.Search do
  @moduledoc """
  A search of one fleet: the posts in its rooms and on its Keys' walls, the
  direct messages of the Keys the reader holds, and the items of its
  workspace whose words match, newest first, a page at a time. Each match is
  read by its own record's search, so each record's policies decide what the
  reader finds: anyone finds the posts in the rooms anyone reads and on the
  Keys' walls, a member finds every room's, only the Keys a reader may read
  and send as (`Keyfleet.Dms.Checks.KeyHolder`) bring their direct messages,
  and only those who read the workspace find its items. Posts written as a
  Key the reader muted are left out, as a room read leaves them out.

  Words are matched as English: "deploys" finds "deployed". A query takes
  the search box's syntax: words in quotes match as a phrase, `or` between
  words matches either, and a leading `-` leaves a word out.

  ## Matches

  Every match is a map with `kind`, `id`, `at` (when it was written, or when
  an item last changed) and `match` (up to 24 of its words around what
  matched), and:

    * `"post"`: `seq`, `room` (`slug` and `name`, nil on a wall), `wall` (the
      Key whose wall it is on, nil in a room), `as_key` (the Key it was
      written as, nil for someone without one) and `agent` (the name of the
      agent that wrote it, or nil);
    * `"dm"`: `seq`, `key` (the reader's Key in it), `other_key`, `from_key`
      and `agent` (the agent that sent it for its person, or nil);
    * `"item"`: `type`, `title`, `project` and `archived`.

  ## Pages

  Matches come newest first, then by kind, then by id, so a page's `cursor`,
  `{at, kind, id}` of its last match, is a place every kind of match is
  ordered against: passed back, the next page starts just after it. A nil
  cursor means nothing older matched.
  """

  alias Keyfleet.{Access, Dms, Graph, Rooms}
  alias Keyfleet.Dms.Checks.KeyHolder

  @kinds ["dm", "item", "post"]
  @max_query 200
  @default_limit 20
  @max_limit 50

  @type cursor :: {DateTime.t(), String.t(), String.t()}

  @doc "The longest query a search takes, in characters."
  def max_query, do: @max_query

  @doc "The most matches a page holds, and how many it holds when not told."
  def limits, do: %{default: @default_limit, max: @max_limit}

  @doc "The kinds of match, in the order matches of one time come in."
  def kinds, do: @kinds

  @doc """
  One page of `actor`'s matches for `query` in the fleet, after `cursor` (nil
  for the newest), at most `limit` of them: `{:ok, %{matches: matches,
  cursor: cursor}}`. A query with no words in it, only words it leaves
  out, a NUL byte, or more than `max_query/0` characters answers
  `{:error, :query}`.
  """
  @spec page(String.t(), String.t(), cursor() | nil, pos_integer(), term()) ::
          {:ok, %{matches: [map()], cursor: cursor() | nil}} | {:error, :query}
  def page(fleet_id, query, cursor, limit \\ @default_limit, actor)
      when is_integer(limit) and limit in 1..@max_limit do
    query = String.trim(query)

    if String.length(query) > @max_query or String.contains?(query, <<0>>) or
         not wants_a_word?(query) do
      {:error, :query}
    else
      args = place(cursor) |> Map.put(:limit, limit)

      matches =
        [
          posts(fleet_id, query, args, actor),
          messages(fleet_id, query, args, actor),
          items(fleet_id, query, args, actor)
        ]
        |> Enum.concat()
        |> Enum.sort_by(&{-DateTime.to_unix(&1.at, :microsecond), &1.kind, &1.id})

      {page, rest} = Enum.split(matches, limit)
      {:ok, %{matches: page, cursor: next(page, rest)}}
    end
  end

  # A query must ask for at least one word: one that only leaves words out
  # matches nearly every row, and no index can find those.
  defp wants_a_word?(query) do
    ~r/-?"[^"]*"?|\S+/u
    |> Regex.scan(query)
    |> Enum.any?(fn [token] ->
      not String.starts_with?(token, "-") and String.downcase(token) != "or"
    end)
  end

  defp place(nil), do: %{}

  defp place({at, kind, id}) when kind in @kinds,
    do: %{before_at: at, before_kind: kind, before_id: id}

  defp next(_page, []), do: nil
  defp next(page, _rest), do: page |> List.last() |> then(&{&1.at, &1.kind, &1.id})

  defp posts(fleet_id, query, args, actor) do
    muted = fleet_id |> Rooms.muted_keys!(actor) |> MapSet.to_list()

    for post <-
          Rooms.search_posts!(fleet_id, query, Map.put(args, :muted, muted), actor: actor) do
      wall? = post.room.kind == :key

      %{
        kind: "post",
        id: post.id,
        at: post.inserted_at,
        match: post.match,
        seq: post.seq,
        room: if(not wall?, do: %{slug: post.room.slug, name: post.room.name}),
        wall: if(wall?, do: post.room.token_id),
        as_key: post.as_key,
        agent: name(post.agent_profile)
      }
    end
  end

  defp messages(fleet_id, query, args, actor) do
    case KeyHolder.held(actor, fleet_id) do
      [] ->
        []

      held ->
        for message <- readable(Dms.search_messages(fleet_id, held, query, args, actor: actor)) do
          mine? = message.from_token_id in held

          %{
            kind: "dm",
            id: message.id,
            at: message.inserted_at,
            match: message.match,
            seq: message.seq,
            key: if(mine?, do: message.from_token_id, else: message.to_token_id),
            other_key: if(mine?, do: message.to_token_id, else: message.from_token_id),
            from_key: message.from_token_id,
            agent: name(message.via_agent)
          }
        end
    end
  end

  defp items(fleet_id, query, args, actor) do
    if Access.allowed?(actor, :read, :workspace, fleet_id) do
      for object <- readable(Graph.search_objects(fleet_id, query, args, actor: actor)) do
        %{
          kind: "item",
          id: object.id,
          at: object.changed,
          match: object.match,
          type: object.type,
          title: object.title,
          project: object.project,
          archived: object.sys["archived"] == true
        }
      end
    else
      []
    end
  end

  # The Keys held or the workspace's readers can change between the check
  # above and the read; what the reader no longer may read is left out.
  defp readable({:ok, records}), do: records
  defp readable({:error, %Ash.Error.Forbidden{}}), do: []
  defp readable({:error, error}), do: raise(error)

  defp name(%{name: name}), do: name
  defp name(_none), do: nil
end
