defmodule KeyfleetWeb.WorldlinePage do
  @moduledoc """
  A fleet's worldline, read: what happened in its rooms, workspace, code,
  notebooks, polls and proposals, as events in time order, each linking to
  the page it happened on. Nothing is stored for it; every page is read
  fresh from the records the fleet already keeps.

  ## Sources

  Each source is read as its own policy lets the reader read it
  (`Keyfleet.Access`):

    * `:posts`: posts and room namings in the rooms the reader reads
      (`Keyfleet.Rooms`). Keys' threads and direct messages are never read.
    * `:changes`: the workspace's notable changes (`Keyfleet.Graph`), for
      whoever reads the workspace.
    * `:pushes`: branches and tags moved in the fleet's code
      (`Keyfleet.Code.Push`), for whoever reads the code.
    * `:notebooks`: notebooks changed, as their daily copies record it
      (`Keyfleet.Notebooks.Backup`), for whoever reads the workspace.
    * `:polls`: polls started (`Keyfleet.Polls.Poll`), for whoever reads
      the polls.
    * `:opened` and `:closed`: proposals opened, and closed as their ballots
      stopped (`Keyfleet.Proposals.Proposal`), for anyone.

  ## Events

  Every event is `%{id:, at:, trail:, kind:, key:, what:, title:, path:, live?:}`.
  `id` is stable across reads and `at` is when it happened. `trail` is the
  line it is drawn on: `"notebooks"`, `"code"`, `"workspace"`,
  `"room:<slug>"` for a room's posts, or `"line"` for proposals and polls,
  drawn on the worldline itself. `kind` is `:post`, `:room_named`,
  `:change`, `:push`, `:notebook`, `:poll`, `:proposal_opened` or
  `:proposal_closed`. `key` is the Key that did it, nil when none did or it
  is not known. `what` is a word or two saying what it was, `title` its
  words, and `path` the page it links to: a page of this site's live view
  when `live?`, or a page opened in full otherwise.

  ## Paging

  Each source is read newest first from its own place, `limit` at a time.
  Below the oldest time a full read reached, that source may hold more it has
  not read, so a page keeps every source's events down to the latest of
  those times, and each source carries on from the last event it kept. A page
  is never empty while anything older is left, never repeats an event, and
  its cursor is nil when nothing older is.

  The first page fixes where every walk begins: the time it was read, by the
  database's clock, and for the workspace the newest change read. Proposals
  close by that time. Anything newer is left to a fresh read.

  The cursor holds atoms, tuples and times, and `page/3` trusts its shape: it
  must never leave the server.
  """

  alias Keyfleet.{Access, Code, Graph, Notebooks, Polls, Projects, Proposals, Repo, Rooms}
  alias KeyfleetWeb.{ActivityLines, KeyLinks, PollsLive, ProposalsPage, WorkspacePage}

  @type source :: :posts | :changes | :pushes | :notebooks | :polls | :opened | :closed
  @type cursor :: %{optional(source()) => term()}
  @type event :: %{
          id: String.t(),
          at: DateTime.t(),
          trail: String.t(),
          kind: atom(),
          key: pos_integer() | nil,
          what: String.t(),
          title: String.t(),
          path: String.t(),
          live?: boolean()
        }

  # Each source and the part of the fleet whose readers read it; the rooms'
  # own policy keeps each room's posts to its readers.
  @sources [
    posts: nil,
    changes: :workspace,
    pushes: :code,
    notebooks: :workspace,
    polls: :polls,
    opened: nil,
    closed: nil
  ]

  @doc """
  A page of the fleet's worldline, oldest first: `%{events: events, cursor: cursor}`.

  `cursor` is nil for the newest page, or the cursor a page answered to read
  the one before it. Options: `:limit`, how many of each source's events are
  read at most (1 to 100), `:only`, the sources read on the newest page (all
  the reader reads by default), and `:actor` and `:context`, who reads it
  (`Keyfleet.Access.context/3`).
  """
  @spec page(String.t(), cursor() | nil, keyword()) :: %{
          events: [event()],
          cursor: cursor() | nil
        }
  def page(fleet_id, cursor, opts) do
    limit = Keyword.fetch!(opts, :limit)
    true = limit in 1..100
    read_as = Keyword.take(opts, [:actor, :context])
    only = Keyword.get(opts, :only, Keyword.keys(@sources))
    positions = cursor || start(Enum.filter(sources(fleet_id, read_as), &(&1 in only)))

    reads =
      Map.new(positions, fn {source, position} ->
        {source, read(source, fleet_id, position, limit, read_as)}
      end)

    floor = floor(reads, limit)

    {kept, cursor} =
      Enum.reduce(reads, {[], %{}}, fn {source, entries}, {kept, cursor} ->
        taken = Enum.take_while(entries, &(floor == nil or not DateTime.before?(&1.at, floor)))

        if length(entries) < limit and length(taken) == length(entries),
          do: {taken ++ kept, cursor},
          else:
            {taken ++ kept, Map.put(cursor, source, carry_on(taken, entries, positions[source]))}
      end)

    %{
      events: kept |> name(fleet_id, read_as) |> Enum.sort_by(&{stamp(&1.at), &1.id}),
      cursor: if(cursor == %{}, do: nil, else: cursor)
    }
  end

  @doc "The sources the reader `read_as` names reads of the fleet's worldline."
  @spec sources(String.t(), keyword()) :: [source()]
  def sources(fleet_id, read_as) do
    class =
      get_in(read_as, [:context, :shared, :access, :class]) ||
        Access.class(read_as[:actor], fleet_id)

    for {source, part} <- @sources, part == nil or Access.enough?(class, :read, part), do: source
  end

  # Where each walk begins: the database's clock, which stamps posts, one
  # microsecond past so that the time itself is included. The workspace's
  # walk begins at its newest change.
  defp start(sources) do
    %Postgrex.Result{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now = DateTime.add(now, 1, :microsecond)
    Map.new(sources, &{&1, if(&1 == :changes, do: nil, else: {now, nil})})
  end

  # The latest of the oldest times the full reads reached, or nil when no read
  # came back full.
  defp floor(reads, limit) do
    reads
    |> Map.values()
    |> Enum.filter(&(length(&1) == limit))
    |> Enum.map(fn entries -> entries |> Enum.map(& &1.at) |> Enum.min(DateTime) end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # A source carries on from the last event it kept. One that kept none
  # carries on from where it was, or for the workspace's first read, just
  # past the newest change it read.
  defp carry_on([], [newest | _], nil), do: newest.position + 1
  defp carry_on([], _entries, position), do: position
  defp carry_on(taken, _entries, _position), do: List.last(taken).position

  defp stamp(at), do: DateTime.to_unix(at, :microsecond)

  # Reading: each source answers its rows newest first, each as an entry
  # with its time and its place in its source.
  defp read(:posts, fleet_id, {at, id}, limit, read_as) do
    fleet_id
    |> Rooms.fleet_lines_before!(at, id, limit, read_as)
    |> Enum.map(&entry(:posts, &1, &1.inserted_at, {&1.inserted_at, &1.id}))
  end

  defp read(:changes, fleet_id, seq, limit, _read_as) do
    fleet_id
    |> Graph.notable_before!(seq, limit)
    |> Enum.map(&entry(:changes, &1, logged(&1.timestamp), &1.seq))
  end

  defp read(:pushes, fleet_id, {at, id}, limit, read_as) do
    fleet_id
    |> Code.pushes_before!(at, id, limit, read_as)
    |> Enum.map(&entry(:pushes, &1, &1.pushed_at, {&1.pushed_at, &1.id}))
  end

  defp read(:notebooks, fleet_id, {at, id}, limit, read_as) do
    fleet_id
    |> Notebooks.backups_changed_before!(at, id, limit, read_as)
    |> Enum.map(&entry(:notebooks, &1, &1.changed_at, {&1.changed_at, &1.id}))
  end

  defp read(:polls, fleet_id, {at, id}, limit, read_as) do
    fleet_id
    |> Polls.polls_started_before!(at, id, limit, read_as)
    |> Enum.map(&entry(:polls, &1, &1.inserted_at, {&1.inserted_at, &1.id}))
  end

  defp read(:opened, fleet_id, {at, id}, limit, _read_as) do
    fleet_id
    |> Proposals.proposals_opened_before!(at, id, limit)
    |> Enum.map(&entry(:opened, &1, &1.opened_at, {&1.opened_at, &1.id}))
  end

  defp read(:closed, fleet_id, {at, id}, limit, _read_as) do
    fleet_id
    |> Proposals.proposals_closed_before!(at, id, limit)
    |> Enum.map(&entry(:closed, &1, &1.closes_at, {&1.closes_at, &1.id}))
  end

  defp entry(source, row, at, position),
    do: %{source: source, row: row, at: at, position: position}

  # The log stamps every change in UTC.
  defp logged(timestamp) do
    {:ok, at, _offset} = DateTime.from_iso8601(timestamp)
    at
  end

  # Naming: what each source's events link to is looked up together for the
  # page, then each entry becomes its event. An event whose page is gone is
  # left out.
  defp name(entries, fleet_id, read_as) do
    by_source = Enum.group_by(entries, & &1.source, & &1.row)
    known = lookup(by_source, fleet_id, read_as)

    Enum.flat_map(entries, fn entry ->
      case event(entry.source, entry.row, fleet_id, known) do
        nil -> []
        event -> [Map.put(event, :at, entry.at)]
      end
    end)
  end

  defp lookup(by_source, fleet_id, read_as) do
    %{
      items: titles(fleet_id, Enum.map(by_source[:changes] || [], &change/1), read_as),
      projects:
        if(by_source[:pushes] || by_source[:notebooks],
          do: Projects.projects!(fleet_id, read_as),
          else: []
        )
    }
  end

  defp titles(_fleet_id, [], _read_as), do: %{}

  defp titles(fleet_id, changes, read_as) do
    ids = changes |> Enum.map(fn {_what, id} -> id end) |> Enum.uniq()
    fleet_id |> Graph.object_titles!(ids, read_as) |> Map.new(&{&1.id, &1.title})
  end

  defp event(:posts, line, fleet_id, _known) do
    %{
      id: "post:#{line.id}",
      trail: "room:#{line.room.slug}",
      kind: line.kind,
      key: line.as_key,
      what: line.room.name,
      title: if(line.kind == :room_named, do: "Named #{line.excerpt}", else: line.excerpt),
      path: KeyLinks.room_path(fleet_id, line.room.slug),
      live?: true
    }
  end

  defp event(:changes, change, fleet_id, known) do
    {what, id} = change(change)
    type = id |> String.split("#", parts: 2) |> hd()

    %{
      id: "change:#{change.seq}",
      trail: "workspace",
      kind: :change,
      key: author(change.actor),
      what: what,
      title:
        known.items[id] || type |> WorkspacePage.type_name() |> elem(0) |> String.capitalize(),
      path: WorkspacePage.item_path(fleet_id, id),
      live?: true
    }
  end

  defp event(:pushes, push, fleet_id, known) do
    case Enum.find(known.projects, &(&1.name == push.project)) do
      %{repository: repository} ->
        %{
          id: "push:#{push.id}",
          trail: "code",
          kind: :push,
          key: push.token_id,
          what: "Push",
          title: "#{moved(push.ref)} in #{push.project}",
          path: Code.commit_path(fleet_id, repository, push.head),
          live?: true
        }

      nil ->
        nil
    end
  end

  defp event(:notebooks, copy, fleet_id, known) do
    case Enum.find(known.projects, &(&1.name == copy.project)) do
      %{hub_project_id: space} when is_binary(space) ->
        %{
          id: "notebook:#{copy.id}",
          trail: "notebooks",
          kind: :notebook,
          key: if(copy.key && copy.key > 0, do: copy.key),
          what: "Notebook",
          title: copy.title,
          path:
            "/fleets/#{fleet_id}/notebooks/open?" <>
              URI.encode_query(to: Notebooks.notebook_path(space, copy.notebook_id)),
          live?: false
        }

      _no_space ->
        nil
    end
  end

  defp event(:polls, poll, fleet_id, _known) do
    %{
      id: "poll:#{poll.id}",
      trail: "line",
      kind: :poll,
      key: poll.started_by_key,
      what: "Poll",
      title: poll.question,
      path: PollsLive.poll_path(fleet_id, poll.id),
      live?: true
    }
  end

  defp event(:opened, proposal, fleet_id, _known) do
    %{
      id: "opened:#{proposal.id}",
      trail: "line",
      kind: :proposal_opened,
      key: proposal.author_key,
      what: "Opened",
      title: ActivityLines.proposal_name(proposal.number),
      path: ProposalsPage.detail_path(fleet_id, proposal.number),
      live?: true
    }
  end

  defp event(:closed, proposal, fleet_id, _known) do
    %{
      id: "closed:#{proposal.id}",
      trail: "line",
      kind: :proposal_closed,
      key: nil,
      what: "Closed",
      title: ActivityLines.proposal_name(proposal.number),
      path: ProposalsPage.detail_path(fleet_id, proposal.number),
      live?: true
    }
  end

  # What a workspace change did, in a word, and the item it links to.
  defp change(%{type: "object.created", brief: %{"object_type" => "review"} = brief}),
    do: {"Review", brief["task"]}

  defp change(%{type: "object.created", brief: brief}),
    do: {type_word(brief["object"]), brief["object"]}

  defp change(%{type: "relation.created", brief: brief}),
    do: {linked(brief["relation_type"]), brief["target"]}

  defp change(%{type: "patch.applied", brief: %{"object" => id} = brief}) do
    values = brief["values"]

    what =
      cond do
        brief["archived"] -> "Archived"
        brief["submitted"] -> "Submitted"
        brief["joins"] > 0 -> "Joined"
        brief["joins"] < 0 -> "Left"
        match?(%{"progress" => %{"new" => _}}, values) -> progress(values["progress"]["new"])
        match?(%{"status" => %{"new" => _}}, values) -> String.capitalize(values["status"]["new"])
        true -> "Edited"
      end

    {what, id}
  end

  defp type_word(id),
    do:
      id
      |> String.split("#", parts: 2)
      |> hd()
      |> WorkspacePage.type_name()
      |> elem(0)
      |> String.capitalize()

  defp linked("supports"), do: "Backed"
  defp linked("contradicts"), do: "Problem"
  defp linked("produces"), do: "Produced"

  defp progress("todo"), do: "To do"
  defp progress(progress), do: String.capitalize(progress)

  # A member writes as its Key; the workspace's own actors write as none.
  defp author(actor) do
    with {token_id, _kind, _wallet} <- Graph.Event.member(actor), do: token_id
  end

  defp moved("refs/heads/" <> branch), do: branch
  defp moved("refs/tags/" <> tag), do: "tag " <> tag
  defp moved(ref), do: ref
end
