defmodule Keyfleet.AtlasTest do
  # The Atlas counts every change once, into a row per thing and a bucket per
  # project and kind, for every span, and reads them back: whatever arrives,
  # in whatever batches, its rows and buckets equal a recount of the changes,
  # from the counter, from the workspace's copied log and from the hub. Only
  # the fleet's members read it, and only the system counts.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Access, Atlas, ChainHelpers, Fleets, Graph, Keys, Projects, Repo}
  alias Keyfleet.Actors.Human
  alias Keyfleet.Atlas.{Count, Fill, ReadHub}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.SignedAgentHelpers

  @system %Keyfleet.Actors.System{}
  @fleet "fleet_tech_classic"
  @spans [:hour, :day, :week, :month, :year]
  @wallet "0x" <> String.duplicate("c3", 20)
  # Three weeks over the turn of the year, so days, weeks, months and years
  # each end inside them.
  @from ~U[2026-12-20 00:00:00Z]
  @minutes 23 * 24 * 60

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  describe "counting" do
    property "a fleet's rows and buckets equal a recount of its changes, however they arrive" do
      check all touches <- touches(),
                sizes <- list_of(integer(1..40), min_length: 1),
                max_runs: 12 do
        fleet = "atlas_#{System.unique_integer([:positive])}"
        for batch <- batches(touches, sizes), do: :ok = Count.count(fleet, batch)

        assert stored_things(fleet) == recount_things(touches)
        assert read_buckets(fleet, touches) == recount_buckets(touches)
      end
    end

    test "the workspace's copied log is counted once, in batches, and keeps up as it grows" do
      Fleets.bootstrap_catalog!()
      Workspace.open_log(@fleet)
      plan = write_log(@fleet, 1..30)

      fill!(@fleet)
      assert caught_up?(@fleet)
      assert stored_things(@fleet) == recount_things(touches_of_log(@fleet, plan))

      plan = write_log(@fleet, 31..45, plan)
      fill!(@fleet)
      touches = touches_of_log(@fleet, plan)
      assert stored_things(@fleet) == recount_things(touches)
      assert read_buckets(@fleet, touches) == recount_buckets(touches)
    end

    test "a copied page is counted as it is copied once the log behind it is, and left to the fill before" do
      Fleets.bootstrap_catalog!()
      Workspace.open_log(@fleet)
      Workspace.create(@fleet, "task", %{"title" => "Before"})
      cursor = Graph.get_cursor!(@fleet, actor: @system)

      page = [
        %{
          "type" => "object.created",
          "actor" => "keyfleet:gateway",
          "timestamp" => "2026-12-21T10:00:00Z",
          "projects" => ["general"],
          "payload" => %{"object" => %{"id" => "goal#90", "type" => "goal"}}
        },
        %{
          "type" => "patch.applied",
          "actor" => "keyfleet:gateway",
          "timestamp" => "2026-12-21T10:05:00Z",
          "projects" => ["general"],
          "payload" => %{"patch" => %{"target" => "goal#90"}}
        }
      ]

      # The log before this page is not counted yet: the page is left to the fill.
      assert :ok = Count.copied(cursor, page, %{}, cursor.applied_seq + 2)
      assert stored_things(@fleet) == []

      fill!(@fleet)
      cursor = Graph.get_cursor!(@fleet, actor: @system)
      assert cursor.counted_seq == cursor.applied_seq

      assert :ok = Count.copied(cursor, page, %{}, cursor.applied_seq + 2)
      assert Graph.get_cursor!(@fleet, actor: @system).counted_seq == cursor.applied_seq + 2

      assert %{changes: 2, keys: [], last_at: ~U[2026-12-21 10:05:00.000000Z]} =
               @fleet
               |> stored_things()
               |> Enum.find(&(&1.thing == "goal#90" and &1.span == :day))
    end
  end

  describe "the hub's notebooks" do
    setup do
      Fleets.bootstrap_catalog!()
      ChainHelpers.deploy!(@fleet)
      hub = hub!(@fleet)

      @fleet
      |> Projects.project!(Projects.general(), actor: @system)
      |> Projects.record_space!("proj-atlas", actor: @system)

      %{hub: hub}
    end

    test "a notebook is counted as made and as saved, once a save, and read since the last one",
         %{hub: hub} do
      listed(hub, [
        notebook("nb-1", ~U[2026-12-21 09:00:00Z], ~U[2026-12-21 11:30:00Z]),
        notebook("nb-2", ~U[2026-12-22 14:00:00Z], ~U[2026-12-22 14:00:00Z])
      ])

      run!()
      assert asked(hub) == [nil]

      # Read again with nothing new, then with one notebook saved again.
      run!()

      assert stored_things(@fleet) |> Enum.filter(&(&1.span == :year)) |> counts() == [
               {"nb-1", 2},
               {"nb-2", 1}
             ]

      listed(hub, [
        notebook("nb-1", ~U[2026-12-21 09:00:00Z], ~U[2026-12-23 08:15:00Z]),
        notebook("nb-2", ~U[2026-12-22 14:00:00Z], ~U[2026-12-22 14:00:00Z])
      ])

      run!()

      # Each read after the first asks from an hour before the last save it knows.
      assert asked(hub) == [nil, "2026-12-22T13:00:00.000000Z", "2026-12-22T13:00:00.000000Z"]

      touches = [
        touch("nb-1", ~U[2026-12-21 09:00:00Z]),
        touch("nb-1", ~U[2026-12-21 11:30:00Z]),
        touch("nb-2", ~U[2026-12-22 14:00:00Z]),
        touch("nb-1", ~U[2026-12-23 08:15:00Z])
      ]

      assert stored_things(@fleet) == recount_things(touches)
      assert read_buckets(@fleet, touches) == recount_buckets(touches)
    end

    test "a hub that can't be read counts nothing", %{hub: hub} do
      listed(hub, :down)

      assert {:error, _reason} =
               ReadHub.perform(%Oban.Job{args: %{"fleet_id" => @fleet}})

      assert stored_things(@fleet) == []
    end
  end

  describe "reading" do
    setup do
      Fleets.bootstrap_catalog!()
      ChainHelpers.deploy!(@fleet)
      ChainHelpers.seed_cursor!(@fleet)
      epoch!(1, @wallet)

      :ok =
        Count.count(@fleet, [
          %{
            thing: "task#1",
            kind: "task",
            project: "general",
            at: ~U[2026-12-21 09:00:00Z],
            key: 1
          },
          %{
            thing: "task#1",
            kind: "task",
            project: "general",
            at: ~U[2026-12-21 09:30:00Z],
            key: 2
          },
          %{
            thing: "task#1",
            kind: "task",
            project: "general",
            at: ~U[2026-12-22 10:00:00Z],
            key: 1
          },
          %{thing: "goal#2", kind: "goal", project: "lab", at: ~U[2026-12-21 12:00:00Z], key: 2},
          %{thing: "goal#2", kind: "goal", project: "lab", at: ~U[2026-12-23 12:00:00Z], key: 2},
          %{
            thing: "nb-3",
            kind: "notebook",
            project: "lab",
            at: ~U[2026-12-22 08:00:00Z],
            key: 1
          },
          %{
            thing: "note#4",
            kind: "note",
            project: "general",
            at: ~U[2026-12-24 07:00:00Z],
            key: nil
          },
          # The week after.
          %{
            thing: "task#5",
            kind: "task",
            project: "general",
            at: ~U[2026-12-29 07:00:00Z],
            key: 1
          }
        ])

      :ok
    end

    test "the most active and the newest of a window, a page at a time, narrowed as asked" do
      member = member()
      week = ~U[2026-12-23 00:00:00Z]

      assert pages(:most_active, week, [], member) == ["task#1", "goal#2", "nb-3", "note#4"]
      assert pages(:newest, week, [], member) == ["note#4", "goal#2", "task#1", "nb-3"]
      assert pages(:newest, week, [source: :notebook], member) == ["nb-3"]
      assert pages(:newest, week, [source: :graph], member) == ["note#4", "goal#2", "task#1"]
      assert pages(:most_active, week, [project: "lab"], member) == ["goal#2", "nb-3"]
      assert pages(:newest, week, [kind: "task"], member) == ["task#1"]
      assert pages(:newest, ~U[2026-12-29 12:00:00Z], [], member) == ["task#5"]

      assert [%{thing: "task#1", changes: 3, actors: 2, last_key: 1}] =
               Atlas.most_active!(@fleet, :week, week, %{kind: "task"}, member).results
    end

    test "the swarm sums projects and kinds as asked, counting a Key at work in two once" do
      member = member()
      from = ~U[2026-12-21 00:00:00Z]
      to = ~U[2026-12-28 00:00:00Z]

      assert [%{at: ^from, changes: 7, things: 4, actors: 2, project: nil, kind: nil}] =
               Atlas.swarm!(@fleet, :week, from, to, %{by: []}, member)

      assert Atlas.swarm!(@fleet, :week, from, to, %{by: [:project]}, member)
             |> Enum.map(&{&1.project, &1.changes, &1.things, &1.actors})
             |> Enum.sort() == [{"general", 4, 2, 2}, {"lab", 3, 2, 2}]

      assert Atlas.swarm!(@fleet, :day, from, to, %{source: :notebook, by: []}, member)
             |> Enum.map(&{&1.at, &1.changes}) == [{~U[2026-12-22 00:00:00Z], 1}]

      assert {:error, %Ash.Error.Invalid{}} =
               Atlas.swarm(@fleet, :hour, from, ~U[2027-03-01 00:00:00Z], %{}, member)
    end

    test "only the fleet's members read it, and only the system counts" do
      from = ~U[2026-12-21 00:00:00Z]
      to = ~U[2026-12-28 00:00:00Z]
      member = %Human{human_account_id: 1, wallet_addresses: [@wallet]}

      stranger = %Human{
        human_account_id: 2,
        wallet_addresses: ["0x" <> String.duplicate("d4", 20)]
      }

      # Membership read from the Keys, and a class a page already read.
      for opts <- [[actor: member], member()] do
        assert {:ok, [_week]} = Atlas.swarm(@fleet, :week, from, to, %{by: []}, opts)
        assert {:ok, %{results: [_ | _]}} = Atlas.newest_things(@fleet, :week, from, opts)
        assert {:ok, %{results: [_ | _]}} = Atlas.most_active(@fleet, :week, from, opts)
      end

      for opts <- [
            [actor: stranger],
            [actor: nil],
            [actor: stranger, context: Access.context(stranger, @fleet, :person)],
            [actor: member, context: Access.context(member, @fleet, :public)]
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = Atlas.swarm(@fleet, :week, from, to, %{}, opts)
        assert {:error, %Ash.Error.Forbidden{}} = Atlas.newest_things(@fleet, :week, from, opts)
        assert {:error, %Ash.Error.Forbidden{}} = Atlas.most_active(@fleet, :week, from, opts)
      end

      row = %{
        fleet_id: @fleet,
        thing: "task#9",
        span: :day,
        start: from,
        kind: "task",
        project: "general",
        changes: 1,
        keys: [1],
        actors: 1,
        last_at: from,
        last_key: 1
      }

      assert {:error, %Ash.Error.Forbidden{}} = Atlas.count_things(row, member())

      assert_raise Ash.Error.Forbidden, fn ->
        Atlas.existing_things!(@fleet, ["task#1"], [from], member())
      end
    end
  end

  ## Changes

  # Up to sixty changes to fifteen things over three weeks, each thing of one
  # kind and project, made as one of four Keys or as nobody's. No two share a
  # minute, so which change came last is never a tie.
  defp touches do
    gen all minutes <- uniq_list_of(integer(0..@minutes), min_length: 1, max_length: 60),
            things <- list_of(integer(0..14), length: length(minutes)),
            keys <- list_of(one_of([constant(nil), integer(1..4)]), length: length(minutes)) do
      [minutes, things, keys]
      |> Enum.zip_with(fn [minute, thing, key] ->
        %{
          thing: "thing-#{thing}",
          kind: Enum.at(~w(task goal note notebook finding), rem(thing, 5)),
          project: Enum.at(~w(general lab), rem(thing, 2)),
          at: DateTime.add(@from, minute * 60 + 7, :second),
          key: key
        }
      end)
    end
  end

  defp batches([], _sizes), do: []

  defp batches(touches, [size | sizes]) do
    {batch, rest} = Enum.split(touches, size)
    [batch | batches(rest, sizes ++ [size])]
  end

  defp touch(notebook, at),
    do: %{thing: notebook, kind: "notebook", project: "general", at: at, key: nil}

  ## The recount

  # The start of each span holding `at`, worked out on its own: a week starts
  # on a Monday.
  defp start(:hour, at), do: %{DateTime.truncate(at, :second) | minute: 0, second: 0}
  defp start(:day, at), do: midnight(DateTime.to_date(at))
  defp start(:week, at), do: at |> DateTime.to_date() |> Date.beginning_of_week() |> midnight()
  defp start(:month, at), do: at |> DateTime.to_date() |> Date.beginning_of_month() |> midnight()
  defp start(:year, at), do: midnight(Date.new!(at.year, 1, 1))

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp recount_things(touches) do
    for span <- @spans,
        {{start, thing}, ts} <- Enum.group_by(touches, &{start(span, &1.at), &1.thing}) do
      last = Enum.max_by(ts, & &1.at, DateTime)
      keys = ts |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

      %{
        span: span,
        start: start,
        thing: thing,
        kind: last.kind,
        project: last.project,
        changes: length(ts),
        keys: keys,
        actors: length(keys),
        last_at: usec(last.at),
        last_key: last.key
      }
    end
    |> Enum.sort_by(&{&1.span, DateTime.to_unix(&1.start), &1.thing})
  end

  defp recount_buckets(touches) do
    for span <- @spans,
        {{start, project, kind}, ts} <-
          Enum.group_by(touches, &{start(span, &1.at), &1.project, &1.kind}) do
      keys = ts |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      {span, start, project, kind, length(ts), ts |> Enum.uniq_by(& &1.thing) |> length(),
       length(keys)}
    end
    |> Enum.sort()
  end

  ## What the Atlas holds

  defp stored_things(fleet) do
    # Every row as stored, held to the recount, not a page of a read.
    from(t in "atlas_things",
      where: t.fleet_id == ^fleet,
      select: %{
        span: t.span,
        start: t.start,
        thing: t.thing,
        kind: t.kind,
        project: t.project,
        changes: t.changes,
        keys: t.keys,
        actors: t.actors,
        last_at: t.last_at,
        last_key: t.last_key
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        row
        | span: String.to_existing_atom(row.span),
          start: DateTime.from_naive!(row.start, "Etc/UTC"),
          last_at: row.last_at |> DateTime.from_naive!("Etc/UTC") |> usec()
      }
    end)
    |> Enum.sort_by(&{&1.span, DateTime.to_unix(&1.start), &1.thing})
  end

  # Every bucket of every span from the first change to the last, through
  # the swarm's own read.
  defp read_buckets(fleet, touches) do
    {first, last} = touches |> Enum.map(& &1.at) |> Enum.min_max_by(&DateTime.to_unix/1)
    opts = [actor: @system, context: Access.context(@system, fleet, :member)]

    for span <- @spans,
        cell <-
          Atlas.swarm!(
            fleet,
            span,
            start(span, first),
            DateTime.add(last, 1),
            %{by: [:project, :kind]},
            opts
          ) do
      {span, cell.at, cell.project, cell.kind, cell.changes, cell.things, cell.actors}
    end
    |> Enum.sort()
  end

  defp usec(%DateTime{} = at), do: %{at | microsecond: {elem(at.microsecond, 0), 6}}

  defp counts(rows), do: rows |> Enum.map(&{&1.thing, &1.changes}) |> Enum.sort()

  ## The copied log

  # Writes `numbers` changes to the log after those `plan` made: each makes a
  # new item or, as often, patches one made before, as one of three Keys, in
  # one of two projects. Answers each item's type and project by id.
  defp write_log(fleet, numbers, plan \\ %{}) do
    Enum.reduce(numbers, plan, fn n, plan ->
      ids = plan |> Map.keys() |> Enum.sort()

      if ids != [] and rem(n, 2) == 0 do
        id = Enum.at(ids, rem(n * 7, length(ids)))
        Workspace.edit(fleet, id, %{"title" => "Edit #{n}"}, by: rem(n, 3) + 1)
        plan
      else
        type = Enum.at(~w(task goal note finding), rem(n, 4))
        project = Enum.at(~w(general lab), rem(n, 2))
        data = %{"title" => "Item #{n}"}
        id = Workspace.create(fleet, type, data, by: rem(n, 3) + 1, project: project)
        Map.put(plan, id, {type, project})
      end
    end)
  end

  # The log's changes to items, recounted from its events: each made or
  # patched item, of the type and in the project it was made with.
  defp touches_of_log(fleet, plan) do
    for event <- Graph.changes_after!(fleet, 0, actor: @system),
        id = event.payload["id"] || get_in(event.payload, ["patch", "target"]),
        {type, project} = Map.fetch!(plan, id) do
      {key, _kind, _wallet} = Graph.Event.member(event.actor)
      {:ok, at, 0} = DateTime.from_iso8601(event.timestamp)
      %{thing: id, kind: type, project: project, at: at, key: key}
    end
  end

  defp fill!(fleet) do
    case Fill.batch(fleet) do
      {:ok, :counted} -> fill!(fleet)
      {:ok, :caught_up} -> :ok
    end
  end

  defp caught_up?(fleet) do
    cursor = Graph.get_cursor!(fleet, actor: @system)
    cursor.counted_seq == cursor.applied_seq
  end

  ## Reading

  defp member do
    member = %Human{human_account_id: 1, wallet_addresses: [@wallet]}
    [actor: member, context: Access.context(member, @fleet, :member)]
  end

  # Every page of a read of the window holding `at`, two things a page.
  defp pages(read, at, filter, opts, after_page \\ nil) do
    page = [limit: 2] ++ if(after_page, do: [after: after_page], else: [])

    result =
      case read do
        :most_active ->
          Atlas.most_active!(@fleet, :week, at, Map.new(filter), [page: page] ++ opts)

        :newest ->
          Atlas.newest_things!(@fleet, :week, at, Map.new(filter), [page: page] ++ opts)
      end

    ids = Enum.map(result.results, & &1.thing)

    if result.more?,
      do: ids ++ pages(read, at, filter, opts, List.last(result.results).__metadata__.keyset),
      else: ids
  end

  defp epoch!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end

  ## The hub

  defp run!, do: assert(:ok = ReadHub.perform(%Oban.Job{args: %{"fleet_id" => @fleet}}))

  # A fleet's hub answering its notebook list with what `listed/2` last put
  # there, only those saved after `updated_after` when it is asked, or
  # refusing it while `:down`. It keeps every `updated_after` it is asked.
  defp hub!(fleet_id) do
    {:ok, hub} = Agent.start_link(fn -> %{items: [], asked: []} end)

    address =
      SignedAgentHelpers.serve!(:hub, fn
        %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-atlas/notebooks"} = conn,
        _opts ->
          after_time = Plug.Conn.fetch_query_params(conn).query_params["updated_after"]
          state = Agent.get_and_update(hub, &{&1, %{&1 | asked: &1.asked ++ [after_time]}})

          case state.items do
            :down ->
              Plug.Conn.send_resp(conn, 503, "")

            items ->
              items = Enum.filter(items, &(after_time == nil or &1.updated_at > after_time))

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                200,
                Jason.encode!(%{success: true, data: %{items: items, next_cursor: nil}})
              )
          end
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(notebooks, :fleets, %{fleet_id => address})
    )

    hub
  end

  defp listed(hub, items), do: Agent.update(hub, &%{&1 | items: items})
  defp asked(hub), do: Agent.get(hub, & &1.asked)

  defp notebook(id, created_at, updated_at),
    do: %{
      id: id,
      title: "Notebook #{id}",
      author: "someone",
      created_at: DateTime.to_iso8601(created_at),
      updated_at: DateTime.to_iso8601(updated_at)
    }
end
