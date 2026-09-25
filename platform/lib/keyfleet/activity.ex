defmodule Keyfleet.Activity do
  @moduledoc """
  What has been happening in a fleet, newest first, read from the records the
  fleet already keeps: its rooms, its workspace, its keys, the agents running
  them and its proposals. Nothing is stored for it; every page is read fresh.

  `page/3` answers a page of items and the cursor to read the next one with;
  `headline/2` answers the one item a fleet's card features.

  ## Items

  Every item is `%{id: id, at: at, kind: kind, facts: facts}`. `id` is stable
  across reads, `at` is when it happened, and `facts` holds what a sentence
  about it needs, with names already looked up. Three shapes recur:

    * a key: `%{token_id: 7, agent: "Ada" | nil}`. `agent` is the agent that
      did the thing, for posts and workspace changes; for a key a task was
      given to, the agent running that key now. `nil` means a person, or no
      agent.
    * an item of the workspace: `%{id: "task#4", type: "task", title: title | nil}`,
      `title` nil when the item is no longer there; a finding also carries
      `confidence`.
    * a room: `%{slug: slug, name: name, topic: topic | nil}`.

  The kinds and their facts:

    * `:post`: `room`, `by` (the key it was written as), `excerpt` (the
      first 160 characters).
    * `:posts`: consecutive posts in one room, at most an hour apart, six
      hours from first to last and fifty in all: `room`, `count`, `keys` (up to
      three different keys, newest first), `others` (how many more keys
      wrote), `excerpt` (of the newest).
    * `:room_named`: `room`, `by`, `topic` (what the room was named).
    * Workspace changes carry `by` (a key, or nil when the workspace itself
      made the change) and `item`:
      * `:created`: a new item of any type;
      * `:claimed`: the task was given to `to` (a key; `to` equal to `by`
        means the key took it on itself);
      * `:unclaimed`: the task is nobody's again;
      * `:progress`: the task's `progress` is now "todo", "doing", "blocked"
        or "done";
      * `:status`: the goal's `status` is now "open", "achieved" or "dropped";
      * `:revised`: a goal, service or launch plan was edited;
      * `:archived`.
    * `:linked`: `by`, `relation` ("supports", "contradicts" or "produces"),
      `source` and `target` (items): the source supports, contradicts or
      produces the target.
    * `:sale`: `token_ids`, the keys bought one after another, lowest first.
    * `:transfer`: `token_id`, a key that changed hands.
    * `:agent_started`: `agent` (`%{id: id, name: name}`), `token_id`.
    * `:agent_stopped`: `agent`, `token_id`, `ended_reason` as the pairing
      recorded it, and `now_runs`: `%{fleet_id: id, fleet_name: name,
      token_id: n}` when the agent was taken on for a key in another fleet
      afterwards and runs it still, otherwise nil.
    * `:proposed`: `number`, `kind` (`:decision`, `:pay` or `:autolaunch`),
      `proposer` (`%{wallet: wallet, token_id: n | nil}`, the lowest key the
      wallet holds today), `gist` (the first 160 characters of its text, or
      nil for a launch), `launch` (`%{name: name, symbol: symbol}` or nil) and
      `payment` (`%{asset: address, amount: atomic units, recipient: address}`
      or nil).
    * `:votes`: consecutive votes on one proposal: `number`, and `yes` and
      `no`, each `%{count: keys, token_ids: up to three, lowest first}`.
    * `:executed`: `number`, `kind`, `payment` and `launch` as for `:proposed`.
    * `:outcome`: a proposal whose vote has closed and been counted:
      `number`, `kind`, `status` (as `Keyfleet.Proposals.status/3`: `:passed`,
      `:failed`, `:executed`, `:expired` or `:closed`), `yes`, `no` and
      `eligible` (keys). Its `at` is when the vote closed.
    * `:open_question` (from `headline/2` only): `goal` (an item) and
      `question`, as `Keyfleet.Graph.open_question/1` finds them.

  ## Times

  Chain records (key sales, proposals, votes and executions) carry no block
  time, only when they were read, so records read together, as in a
  backfill, share one time. Workspace changes carry the time the workspace
  logged them, posts the time they were written, and an agent starting or
  stopping the time it was approved or ended.

  ## Paging

  Each source is read newest first from its own place in the cursor and
  grouped on its own, and the sources are merged by time, and at the same
  time in a fixed order of sources. A source that has handed over all it
  read is read again from where it stopped, twice at most in one page: a
  page that would need a third read of one source ends there, short, with a
  cursor. So a page holds `limit` items or fewer, a page is never empty, and
  a cursor means more is left; nil means nothing older is.

  The first page fixes where the walk begins for every source: the time it
  was read for posts (by the database's clock, which stamps them) and for
  agents starting and stopping (by this server's clock, which stamps them),
  how far votes had been counted for outcomes (none to read when no vote
  had), and one past the newest record it read for the workspace, keys and
  proposals. Everything recorded after the first page is left to a fresh
  read, so walking the pages with the cursors answered gives every item
  once, in the same order as one larger read made when the first page was.

  An outcome shows once the chain has been read past the vote's close. One
  counted after the first page was read appears on a fresh read, never in the
  history a walk has already passed, even when its vote closed earlier.

  The cursor holds atoms, tuples and times, and `page/3` trusts its shape: it
  must never leave the server. Keep it in the process that read the page (a
  LiveView's assigns) and hand it back unchanged.

  ## For pages that show it live

  When something new happens, read the first page again rather than the
  pages after it, and read it once for a burst of changes to one fleet, not
  once per change.
  """

  alias Keyfleet.Agents
  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @type position :: nil | integer() | {DateTime.t(), term()}
  @type cursor :: %{
          posts: position(),
          graph: position(),
          keys: position(),
          arrivals: position(),
          departures: position(),
          proposals: position(),
          outcomes: position()
        }
  @type item :: %{id: String.t(), at: DateTime.t(), kind: atom(), facts: map()}

  # The sources, in the order they come in when their items share a time.
  @sources [:outcomes, :proposals, :keys, :departures, :arrivals, :graph, :posts]
  @page 30
  # Grouped sources read more rows than a page holds, and a group is capped
  # below the rows read, so a full read always holds a whole group to keep.
  # A source is read at most this many times for one page.
  @reads_per_page 2
  @posts_read 200
  @votes_read 100
  @keys_read 100
  @group_cap 50
  @post_gap 3_600_000_000
  @post_span 21_600_000_000
  @listed_keys 3
  @excerpt 160
  @recent 7 * 86_400
  @member ~r/\Amember:[0-9]+:0x[0-9a-f]{40}:([0-9]+)@[0-9]+\/(human|agent):(0x[0-9a-f]{40})\z/

  @doc """
  A page of the fleet's activity, newest first: `%{items: items, cursor: cursor}`.

  `cursor` is nil for the newest page, or the cursor a page answered to read
  the one after it. Options: `:limit`, the most items a page holds (1 to
  #{@page}, #{@page} by default), and `:now`, the time outcomes are counted up to.
  """
  @spec page(String.t(), cursor() | nil, keyword()) :: %{items: [item()], cursor: cursor() | nil}
  def page(fleet_id, cursor, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    true = limit in 1..@page
    # One database session for the whole page: the clock the first page
    # reads is the one that stamped the posts it reads.
    Repo.checkout(fn -> read_page(fleet_id, cursor, limit, now) end)
  end

  defp read_page(fleet_id, cursor, limit, now) do
    chain = Chain.get_cursor!(fleet_id)
    positions = cursor || start(chain, now)

    # A read that came back full leaves out its last entry, which may be the
    # start of a group it did not read to the end.
    fetch = fn source, position, reads ->
      {entries, more?, top} = read(source, fleet_id, position, limit, chain, now)
      entries = if more?, do: Enum.drop(entries, -1), else: entries
      %{entries: entries, more?: more?, position: position || top, reads: reads + 1}
    end

    streams = Map.new(@sources, &{&1, fetch.(&1, positions[&1], 0)})
    {taken, streams} = merge(streams, limit, [], fetch)

    %{items: name(taken, fleet_id), cursor: next_cursor(streams)}
  end

  # Where a walk begins in each source. The sources kept in time order are
  # read up to now by the clock that stamps them (the database's for posts,
  # this server's for agents starting and stopping) and outcomes up to what
  # has been counted, each place one microsecond past so that the time itself
  # is included; nil outcomes means none have been counted, so there are none
  # to read. The sources kept in record order begin just past the newest
  # record their first read finds.
  defp start(chain, now) do
    %Postgrex.Result{rows: [[written]]} = Repo.query!("SELECT clock_timestamp()")
    stamped = DateTime.utc_now()

    %{
      posts: just_after(written),
      graph: nil,
      keys: nil,
      arrivals: just_after(stamped),
      departures: just_after(stamped),
      proposals: nil,
      outcomes: chain |> through(now) |> just_after()
    }
  end

  defp just_after(nil), do: nil
  defp just_after(at), do: {DateTime.add(at, 1, :microsecond), nil}

  # Votes are counted up to where the chain has been read, and never past now.
  defp through(%{read_through_at: %DateTime{} = read_through_at}, now),
    do: Enum.min_by([now, read_through_at], &stamp/1)

  defp through(_chain, _now), do: nil

  @doc """
  The item a fleet features at `now`, by the first rule that finds one:

    1. the latest `contradicts` link, if made in the last seven days;
    2. the latest goal achieved, task marked done or proposal carried out, if
       in the last seven days;
    3. the first open question of the most recently changed open goal;
    4. the fleet's latest item.

  Links, achieved goals and finished tasks are looked for among the fleet's
  200 latest notable workspace changes. Nil when the fleet has no activity.
  """
  @spec headline(String.t(), DateTime.t()) :: item() | nil
  def headline(fleet_id, %DateTime{} = now) do
    since = DateTime.add(now, -@recent, :second)

    featured =
      recent(mark(fleet_id, :contradiction), since) ||
        newest([
          recent(mark(fleet_id, :completion), since),
          recent(last_execution(fleet_id), since)
        ]) ||
        open_question(fleet_id)

    case featured do
      nil -> fleet_id |> page(nil, limit: 1, now: now) |> Map.fetch!(:items) |> List.first()
      entry -> entry |> List.wrap() |> name(fleet_id) |> hd()
    end
  end

  defp mark(fleet_id, mark) do
    case Graph.latest_mark!(fleet_id, mark) do
      nil -> nil
      event -> graph_entry(event)
    end
  end

  defp last_execution(fleet_id) do
    fleet_id
    |> Proposals.executions_recorded_before!(nil, 1)
    |> Enum.map(&execution_entry/1)
    |> List.first()
  end

  defp recent(nil, _since), do: nil
  defp recent(entry, since), do: if(DateTime.before?(entry.at, since), do: nil, else: entry)

  defp newest(entries) do
    entries |> Enum.reject(&is_nil/1) |> Enum.max_by(&stamp(&1.at), fn -> nil end)
  end

  defp open_question(fleet_id) do
    case Graph.open_question(fleet_id) do
      %{goal: goal, question: question} ->
        entry("question:#{goal.id}", at(goal.changed_at), :open_question, nil, %{
          goal: {:item, goal.id},
          question: question
        })

      nil ->
        nil
    end
  end

  # Merging: the newest head among the sources goes next, until the page is
  # full or every source is done. A source that has handed over all it read
  # and has more is read again first, since its next item could be newer than
  # any other; each read hands over at least one entry. A source already
  # read as often as a page allows ends the page there.
  defp merge(streams, 0, taken, _fetch), do: {Enum.reverse(taken), streams}

  defp merge(streams, left, taken, fetch) do
    case Enum.find(@sources, &(streams[&1].entries == [] and streams[&1].more?)) do
      nil ->
        take(streams, left, taken, fetch)

      dry ->
        case streams[dry] do
          %{reads: @reads_per_page} ->
            {Enum.reverse(taken), streams}

          %{position: position, reads: reads} ->
            merge(Map.put(streams, dry, fetch.(dry, position, reads)), left, taken, fetch)
        end
    end
  end

  defp take(streams, left, taken, fetch) do
    case next_source(streams) do
      nil ->
        {Enum.reverse(taken), streams}

      source ->
        %{entries: [entry | rest]} = stream = Map.fetch!(streams, source)
        stream = %{stream | entries: rest, position: entry.position}
        merge(Map.put(streams, source, stream), left - 1, [entry | taken], fetch)
    end
  end

  defp next_source(streams) do
    @sources
    |> Enum.with_index()
    |> Enum.filter(fn {source, _rank} -> streams[source].entries != [] end)
    |> Enum.max_by(fn {source, rank} -> {stamp(hd(streams[source].entries).at), -rank} end, fn ->
      nil
    end)
    |> case do
      nil -> nil
      {source, _rank} -> source
    end
  end

  defp next_cursor(streams) do
    if Enum.all?(streams, fn {_source, s} -> s.entries == [] and not s.more? end),
      do: nil,
      else: Map.new(streams, fn {source, s} -> {source, s.position} end)
  end

  defp stamp(at), do: DateTime.to_unix(at, :microsecond)

  # Reading: each source answers its entries newest first, whether it has
  # more beyond them, and, for a source kept in record order, the place just
  # past the newest record read, where a walk begins. Each entry carries the
  # place in its source just past it.
  defp read(:posts, fleet_id, {at, id}, _limit, _chain, _now) do
    lines = Rooms.fleet_lines_before!(fleet_id, at, id, @posts_read)
    {group_lines(lines), length(lines) == @posts_read, nil}
  end

  defp read(:graph, fleet_id, seq, limit, _chain, _now) do
    events = Graph.notable_before!(fleet_id, seq, limit + 1)
    {Enum.map(events, &graph_entry/1), length(events) > limit, top(events, :seq)}
  end

  defp read(:keys, fleet_id, seq, _limit, _chain, _now) do
    epochs = Keys.epochs_recorded_before!(fleet_id, seq, @keys_read)
    {group_epochs(epochs), length(epochs) == @keys_read, top(epochs, :record_seq)}
  end

  defp read(:arrivals, fleet_id, {at, id}, limit, _chain, _now) do
    pairings = Keys.arrivals_before!(fleet_id, at, id, limit + 1)

    entries =
      Enum.map(pairings, fn pairing ->
        entry(
          "arrival:#{pairing.id}",
          pairing.approved_at,
          :agent_started,
          {pairing.approved_at, pairing.id},
          %{agent: agent(pairing.agent_profile), token_id: pairing.token_id}
        )
      end)

    {entries, length(pairings) > limit, nil}
  end

  defp read(:departures, fleet_id, {at, id}, limit, _chain, _now) do
    pairings = Keys.departures_before!(fleet_id, at, id, limit + 1)

    entries =
      Enum.map(pairings, fn pairing ->
        entry(
          "departure:#{pairing.id}",
          pairing.ended_at,
          :agent_stopped,
          {pairing.ended_at, pairing.id},
          %{
            agent: agent(pairing.agent_profile),
            token_id: pairing.token_id,
            ended_reason: pairing.ended_reason,
            now_runs: {:elsewhere, pairing.agent_profile_id, pairing.ended_at}
          }
        )
      end)

    {entries, length(pairings) > limit, nil}
  end

  defp read(:proposals, fleet_id, seq, limit, _chain, _now) do
    reads = [
      {Proposals.proposals_recorded_before!(fleet_id, seq, limit + 1), limit + 1},
      {Proposals.votes_recorded_before!(fleet_id, seq, @votes_read), @votes_read},
      {Proposals.executions_recorded_before!(fleet_id, seq, limit + 1), limit + 1}
    ]

    # Each kind of record is read to its own depth. Below the shallowest
    # full read's last record, a record of that kind may be missing, so the
    # records are merged only down to there.
    floor =
      reads
      |> Enum.filter(fn {records, wanted} -> length(records) == wanted end)
      |> Enum.map(fn {records, _wanted} -> List.last(records).record_seq end)
      |> Enum.max(fn -> 0 end)

    records = reads |> Enum.flat_map(&elem(&1, 0)) |> Enum.sort_by(& &1.record_seq, :desc)
    complete = Enum.filter(records, &(&1.record_seq >= floor))

    {group_records(complete), floor > 0, top(records, :record_seq)}
  end

  defp read(:outcomes, _fleet_id, nil, _limit, _chain, _now), do: {[], false, nil}

  defp read(:outcomes, fleet_id, {at, number}, limit, chain, now) do
    proposals = Proposals.proposals_closed_before!(fleet_id, at, number, limit + 1)

    entries =
      Enum.map(proposals, fn proposal ->
        entry(
          "outcome:#{proposal.number}",
          proposal.closes_at,
          :outcome,
          {proposal.closes_at, proposal.number},
          %{
            number: proposal.number,
            kind: proposal.kind,
            status: Proposals.status(proposal, chain, now),
            yes: proposal.yes_keys,
            no: proposal.no_keys,
            eligible: proposal.eligible_keys
          }
        )
      end)

    {entries, length(proposals) > limit, nil}
  end

  defp top([], _field), do: 1
  defp top([newest | _], field), do: Map.fetch!(newest, field) + 1

  defp entry(id, at, kind, position, facts),
    do: %{id: id, at: at, kind: kind, position: position, facts: facts}

  # Posts: a run of posts in one room, each at most an hour after the one
  # before, six hours at most from the first and fifty in all, is one item.
  defp group_lines([]), do: []

  defp group_lines([%{kind: :room_named} = line | rest]) do
    item =
      entry("room_named:#{line.id}", line.inserted_at, :room_named, line_position(line), %{
        room: room(line.room),
        by: author(line),
        topic: line.excerpt
      })

    [item | group_lines(rest)]
  end

  defp group_lines([first | rest]) do
    {run, rest} = take_run(rest, first, [first])
    [posts_entry(Enum.reverse(run)) | group_lines(rest)]
  end

  defp take_run([next | rest], first, [last | _] = run) do
    if next.kind == :post and next.room_id == first.room_id and length(run) < @group_cap and
         DateTime.diff(last.inserted_at, next.inserted_at, :microsecond) <= @post_gap and
         DateTime.diff(first.inserted_at, next.inserted_at, :microsecond) <= @post_span,
       do: take_run(rest, first, [next | run]),
       else: {run, [next | rest]}
  end

  defp take_run([], _first, run), do: {run, []}

  defp posts_entry([newest] = _run) do
    entry("posts:#{newest.id}", newest.inserted_at, :post, line_position(newest), %{
      room: room(newest.room),
      by: author(newest),
      excerpt: newest.excerpt
    })
  end

  defp posts_entry([newest | _] = run) do
    keys = run |> Enum.map(&author/1) |> Enum.uniq_by(& &1.token_id)

    entry("posts:#{newest.id}", newest.inserted_at, :posts, line_position(List.last(run)), %{
      room: room(newest.room),
      count: length(run),
      keys: Enum.take(keys, @listed_keys),
      others: max(length(keys) - @listed_keys, 0),
      excerpt: newest.excerpt
    })
  end

  defp line_position(line), do: {line.inserted_at, line.id}

  defp room(room), do: %{slug: room.slug, name: room.name, topic: room.topic}

  defp author(line),
    do: %{token_id: line.as_key, agent: line.agent_profile && line.agent_profile.name}

  # Keys: consecutive first sales are one item, fifty at most.
  defp group_epochs([]), do: []

  defp group_epochs([%{ownership_epoch: 0} = first | _] = epochs) do
    {sold, rest} =
      epochs |> Enum.take(@group_cap) |> Enum.split_while(&(&1.ownership_epoch == 0))

    rest = rest ++ Enum.drop(epochs, @group_cap)
    last = List.last(sold)

    item =
      entry("sale:#{first.record_seq}", first.observed_at, :sale, last.record_seq, %{
        token_ids: sold |> Enum.map(& &1.token_id) |> Enum.sort()
      })

    [item | group_epochs(rest)]
  end

  defp group_epochs([epoch | rest]) do
    item =
      entry("transfer:#{epoch.record_seq}", epoch.observed_at, :transfer, epoch.record_seq, %{
        token_id: epoch.token_id
      })

    [item | group_epochs(rest)]
  end

  # Proposal records: consecutive votes on one proposal are one item, fifty
  # votes at most.
  defp group_records([]), do: []

  defp group_records([%Proposals.Vote{} = first | _] = records) do
    {votes, rest} =
      records
      |> Enum.take(@group_cap)
      |> Enum.split_while(
        &match?(%Proposals.Vote{proposal_id: id} when id == first.proposal_id, &1)
      )

    rest = rest ++ Enum.drop(records, @group_cap)
    {yes, no} = Enum.split_with(votes, & &1.support)

    item =
      entry(
        "votes:#{first.record_seq}",
        first.observed_at,
        :votes,
        List.last(votes).record_seq,
        %{
          number: first.proposal_number,
          yes: tally(yes),
          no: tally(no)
        }
      )

    [item | group_records(rest)]
  end

  defp group_records([%Proposals.Proposal{} = proposal | rest]) do
    item =
      entry(
        "proposal:#{proposal.record_seq}",
        proposal.observed_at,
        :proposed,
        proposal.record_seq,
        Map.merge(offer(proposal), %{
          number: proposal.number,
          kind: proposal.kind,
          proposer: {:holder, proposal.proposer},
          gist: gist(proposal)
        })
      )

    [item | group_records(rest)]
  end

  defp group_records([%Proposals.Execution{} = execution | rest]),
    do: [execution_entry(execution) | group_records(rest)]

  defp execution_entry(execution) do
    %{proposal: proposal} = execution

    entry(
      "executed:#{execution.record_seq}",
      execution.observed_at,
      :executed,
      execution.record_seq,
      Map.merge(offer(proposal), %{number: proposal.number, kind: proposal.kind})
    )
  end

  defp tally(votes) do
    token_ids = votes |> Enum.flat_map(& &1.token_ids) |> Enum.uniq() |> Enum.sort()
    %{count: length(token_ids), token_ids: Enum.take(token_ids, @listed_keys)}
  end

  # What a payment pays or a launch launches.
  defp offer(%{kind: :pay} = proposal) do
    %{
      payment: %{asset: proposal.asset, amount: proposal.amount, recipient: proposal.recipient},
      launch: nil
    }
  end

  defp offer(%{kind: :autolaunch, launch_envelope: %{} = launch}) do
    %{
      payment: nil,
      launch: %{name: text(launch.name, 64), symbol: text(launch.symbol, 16)}
    }
  end

  defp offer(_proposal), do: %{payment: nil, launch: nil}

  defp gist(%{text_start: nil}), do: nil
  defp gist(%{text_start: bytes}), do: text(bytes, @excerpt)

  # Chain texts are bytes that need not be valid text.
  defp text(bytes, length), do: bytes |> String.replace_invalid() |> String.slice(0, length)

  # Workspace changes.
  defp graph_entry(event) do
    {kind, facts} = change(event.type, event.brief)

    entry(
      "graph:#{event.seq}",
      at(event.timestamp),
      kind,
      event.seq,
      Map.put(facts, :by, actor(event.actor))
    )
  end

  defp change("object.created", brief), do: {:created, %{item: {:item, brief["object"]}}}

  defp change("relation.created", brief) do
    {:linked,
     %{
       relation: brief["relation_type"],
       source: {:item, brief["source"]},
       target: {:item, brief["target"]}
     }}
  end

  defp change("patch.applied", %{"object" => id} = brief) do
    values = brief["values"]
    item = %{item: {:item, id}}

    cond do
      brief["archived"] ->
        {:archived, item}

      "assignee_key" in brief["fields"] ->
        case values["assignee_key"] do
          %{"new" => token_id} when is_integer(token_id) ->
            {:claimed, Map.put(item, :to, {:runner, token_id})}

          _unset ->
            {:unclaimed, item}
        end

      match?(%{"progress" => %{"new" => _}}, values) ->
        {:progress, Map.put(item, :progress, values["progress"]["new"])}

      match?(%{"status" => %{"new" => _}}, values) ->
        {:status, Map.put(item, :status, values["status"]["new"])}

      true ->
        {:revised, item}
    end
  end

  # A member writes as its key; the workspace's own actors write as
  # `keyfleet:<part>`. Any other actor is not one the workspace records.
  defp actor("keyfleet:" <> _part), do: nil

  defp actor(actor) do
    case Regex.run(@member, actor, capture: :all_but_first) do
      [token_id, "agent", wallet] -> {:actor, String.to_integer(token_id), wallet}
      [token_id, "human", _wallet] -> %{token_id: String.to_integer(token_id), agent: nil}
    end
  end

  # The log stamps every event in UTC.
  defp at(timestamp) do
    {:ok, at, _offset} = DateTime.from_iso8601(timestamp)
    at
  end

  defp agent(profile), do: %{id: profile.id, name: profile.name}

  # Naming: the facts hold references (`{:actor, token_id, wallet}`,
  # `{:runner, token_id}`, `{:holder, wallet}`, `{:item, id}` and
  # `{:elsewhere, agent_profile_id, ended_at}`), looked up together for the
  # whole page, a batch per kind of reference.
  defp name([], _fleet_id), do: []

  defp name(entries, fleet_id) do
    refs = entries |> Enum.flat_map(&refs(&1.facts)) |> Enum.group_by(&elem(&1, 0))
    names = lookup(refs, fleet_id)

    Enum.map(entries, fn entry ->
      %{id: entry.id, at: entry.at, kind: entry.kind, facts: resolve(entry.facts, names)}
    end)
  end

  defp refs(facts) when is_map(facts) and not is_struct(facts),
    do: facts |> Map.values() |> Enum.flat_map(&refs/1)

  defp refs(values) when is_list(values), do: Enum.flat_map(values, &refs/1)

  defp refs(ref)
       when is_tuple(ref) and elem(ref, 0) in [:actor, :runner, :holder, :item, :elsewhere],
       do: [ref]

  defp refs(_value), do: []

  defp lookup(refs, fleet_id) do
    %{
      actor: agents_by_wallet(refs[:actor]),
      runner: runners(fleet_id, refs[:runner]),
      holder: holders(fleet_id, refs[:holder]),
      item: items(fleet_id, refs[:item]),
      elsewhere: elsewhere(fleet_id, refs[:elsewhere])
    }
  end

  defp agents_by_wallet(nil), do: %{}

  defp agents_by_wallet(refs) do
    refs
    |> Enum.map(&elem(&1, 2))
    |> Enum.uniq()
    |> Agents.agents_by_wallets!()
    |> Map.new(&{&1.wallet_address, &1.name})
  end

  defp runners(_fleet_id, nil), do: %{}

  defp runners(fleet_id, refs) do
    refs
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.flat_map(&Keys.fleet_operators!(fleet_id, &1))
    |> Map.new(&{&1.token_id, &1.agent_profile.name})
  end

  defp holders(_fleet_id, nil), do: %{}

  defp holders(fleet_id, refs) do
    wallets = refs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    fleet_id
    |> Keys.lowest_keys_held!(wallets)
    |> Map.new(&{&1.owner_wallet, &1.token_id})
  end

  defp items(_fleet_id, nil), do: %{}

  defp items(fleet_id, refs) do
    ids = refs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    fleet_id
    |> Graph.object_titles!(ids, load: [:card])
    |> Map.new(&{&1.id, &1})
  end

  defp elsewhere(_fleet_id, nil), do: %{}

  defp elsewhere(fleet_id, refs) do
    ids = refs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    after_at = refs |> Enum.map(&elem(&1, 2)) |> Enum.min_by(&stamp/1)
    fleets = Map.new(Fleets.catalog(), &{&1.id, &1.name})

    fleet_id
    |> Keys.runs_elsewhere!(ids, after_at)
    |> Map.new(fn pairing ->
      {pairing.agent_profile_id,
       %{
         fleet_id: pairing.fleet_id,
         fleet_name: Map.fetch!(fleets, pairing.fleet_id),
         token_id: pairing.token_id,
         approved_at: pairing.approved_at
       }}
    end)
  end

  defp resolve(facts, names) when is_map(facts) and not is_struct(facts),
    do: Map.new(facts, fn {key, value} -> {key, resolve(value, names)} end)

  defp resolve(values, names) when is_list(values), do: Enum.map(values, &resolve(&1, names))

  defp resolve({:actor, token_id, wallet}, names),
    do: %{token_id: token_id, agent: names.actor[wallet]}

  defp resolve({:runner, token_id}, names),
    do: %{token_id: token_id, agent: names.runner[token_id]}

  defp resolve({:holder, wallet}, names), do: %{wallet: wallet, token_id: names.holder[wallet]}

  defp resolve({:item, id}, names) do
    type = id |> String.split("#", parts: 2) |> hd()

    case names.item[id] do
      nil -> %{id: id, type: type, title: nil}
      %{type: "finding"} = object -> finding(object)
      object -> %{id: id, type: object.type, title: object.title}
    end
  end

  defp resolve({:elsewhere, agent_profile_id, ended_at}, names) do
    case names.elsewhere[agent_profile_id] do
      %{approved_at: approved_at} = runs ->
        if DateTime.after?(approved_at, ended_at), do: Map.delete(runs, :approved_at)

      nil ->
        nil
    end
  end

  defp resolve(value, _names), do: value

  defp finding(object),
    do: %{
      id: object.id,
      type: "finding",
      title: object.title,
      confidence: object.card["confidence"]
    }
end
