defmodule Keyfleet.Graph.ProjectionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CommittedCatalog
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Projection
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @system %Actors.System{}
  @wallet "0x" <> String.duplicate("a1", 20)
  @contract "0x" <> String.duplicate("b2", 20)
  # Owns key 1 of `@fleet`, so it may read the fleet's workspace.
  @holder %Actors.Human{human_account_id: 1, wallet_addresses: [@wallet]}
  @tables [Graph.Cursor, Graph.Event, Graph.Object, Graph.Relation]
  @page_bytes 512 * 1024

  setup %{tmp_dir: tmp_dir} = context do
    if context[:independent_connections] do
      added_fleets = Sandbox.unboxed_run(Repo, &CommittedCatalog.commit!/0)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn -> CommittedCatalog.remove!(added_fleets) end)
      end)
    else
      # Workspace reads take a repeatable-read snapshot, which Postgres allows
      # inside the sandbox only when its transaction is at that level already.
      owner = Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
      on_exit(fn -> Sandbox.stop_owner(owner) end)
      Fleets.bootstrap_catalog!()
      Rooms.bootstrap_rooms!(Fleets.catalog_ids())
      own_key!()
      start_writer(Path.join(tmp_dir, "graph"))
    end

    %{tmp_dir: tmp_dir}
  end

  test "removing the read tables and starting the projector again copies them back the same" do
    start_projector(catch_up_interval: 60_000)
    {head, ids} = build_workspace()
    run_id = log_id()
    assert Projector.await(@fleet, run_id, head) == head
    copied = tables()

    objects = Map.new(copied[Graph.Object], &{&1.id, &1})
    {goal, task} = {objects[ids.goal], objects[ids.task]}
    assert goal.sys["archived"] == true
    assert {task.version, task.data["progress"]} == {2, "doing"}
    assert length(copied[Graph.Relation]) == 2
    assert [%{run_id: ^run_id, applied_seq: ^head}] = copied[Graph.Cursor]

    # Each object last changed at its creation or its latest patch.
    last_changes =
      for %{type: type} = event <- Enum.sort_by(copied[Graph.Event], & &1.seq),
          type in ~w(object.created patch.applied),
          into: %{},
          do: {event.payload["id"] || event.payload["target"], event}

    assert map_size(last_changes) == 4

    for {id, event} <- last_changes do
      assert {objects[id].changed_seq, objects[id].changed_at} == {event.seq, event.timestamp}
    end

    assert goal.changed_seq > task.changed_seq

    # A reader sees who asked for each write and what it did; the authority
    # stamp stays in the log.
    for %{type: "keyfleet.command", payload: payload} <- copied[Graph.Event] do
      assert Enum.sort(Map.keys(payload)) == ~w(events op principal result)
    end

    stop_supervised!(Keyfleet.Graph.Projectors)
    @fleet |> Graph.get_cursor!(actor: @system) |> Graph.forget_cursor!(actor: @system)
    assert Enum.all?(Map.values(tables()), &(&1 == []))

    start_projector(catch_up_interval: 60_000)
    assert Projector.await(@fleet, run_id, head) == head
    assert tables() == copied
  end

  test "a copy from another log is thrown away and copied again" do
    start_projector(catch_up_interval: 60_000)
    {head, _ids} = build_workspace()
    assert Projector.await(@fleet, log_id(), head) == head
    copied = tables()

    stop_supervised!(Keyfleet.Graph.Projectors)
    @fleet |> Graph.get_cursor!(actor: @system) |> Graph.forget_cursor!(actor: @system)
    Graph.start_cursor!(%{fleet_id: @fleet, run_id: "log_elsewhere"}, actor: @system)

    start_projector(catch_up_interval: 60_000)
    assert Projector.await(@fleet, log_id(), head) == head
    assert tables() == copied
  end

  # A log file replaced by a fresh one, as when a volume is lost or restored:
  # its places count from 1 again, and it may end up shorter than the old log
  # or not.
  test "a log replaced by a shorter fresh one is copied from the new log alone", c do
    {old_head, new_head} = replace_log(c, fn _old_head -> write_notes(1, 1) end)
    assert new_head < old_head
  end

  test "a log replaced by a fresh one at least as long is copied from the new log alone", c do
    {old_head, new_head} = replace_log(c, &write_notes(1, &1))
    assert new_head >= old_head
  end

  # A backup of the file keeps the log's id, but not what was written after
  # it was taken: the copy has reached past the restored log's head. The
  # running projector learns that on its next round, as a fresh one does.
  test "a log restored from an older backup of its file is copied again from that backup",
       %{tmp_dir: tmp_dir} do
    start_projector(catch_up_interval: 60_000)
    run_id = log_id()
    kept = write!("create", note("Kept"), "kept-1")
    assert Projector.await(@fleet, run_id, kept) == kept

    back_up(Path.join(tmp_dir, "graph"), Path.join(tmp_dir, "backup"))
    lost = Enum.reduce(1..3, 0, fn n, _ -> write!("create", note("Lost #{n}"), "lost-#{n}") end)
    assert Projector.await(@fleet, run_id, lost) == lost

    stop_supervised!(Keyfleet.Graph.Supervisor)
    start_writer(Path.join(tmp_dir, "backup"))
    assert log_id() == run_id
    restored = write!("create", note("Restored"), "restored-1")
    assert restored < lost

    stop_supervised!(Keyfleet.Graph.Projectors)
    start_projector(catch_up_interval: 60_000)
    assert Projector.await(@fleet, run_id, restored) == restored

    titles = for object <- tables()[Graph.Object], do: object.data["title"]
    assert Enum.sort(titles) == ["Kept", "Restored"]
    assert [%{applied_seq: ^restored}] = tables()[Graph.Cursor]
  end

  test "a copy whose log is replaced between its pages stops and copies nothing of the new log",
       %{tmp_dir: tmp_dir} do
    write!("create", note("Old"), "old-1")
    Graph.start_cursor!(%{fleet_id: @fleet, run_id: log_id()}, actor: @system)
    hold_after_cursor_read()

    test = self()
    copier = Task.async(fn -> hold_here(test, fn -> Projection.catch_up(@fleet) end) end)
    assert_receive {:held, pid}, 10_000

    stop_supervised!(Keyfleet.Graph.Supervisor)
    start_writer(Path.join(tmp_dir, "fresh"))
    write!("create", note("Fresh"), "fresh-1")
    new_run = log_id()
    send(pid, :go)

    assert Task.await(copier, 30_000) == {:error, {:log_replaced, new_run}}
    assert tables()[Graph.Event] == []
    assert tables()[Graph.Object] == []
    assert [%{applied_seq: 0}] = tables()[Graph.Cursor]
  end

  test "a write the projector was never told about is copied on its next round" do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Graph.head_topic(@fleet))
    start_projector(catch_up_interval: 200)

    # Straight to the writer, so nothing asks the projector to copy it.
    {:ok, %{"head_seq" => head, "result" => %{"id" => id}}} =
      command("create", note("Unannounced"), "quiet-1")

    assert await_head(log_id(), head) == head
    assert Graph.read_object!(@fleet, id, actor: @holder).data["title"] == "Unannounced"
  end

  test "a link removed on a later page than the one that made it is gone, and a patch keeps the fields it does not name" do
    start_projector(catch_up_interval: 60_000)
    run_id = log_id()
    goal = created!("goal", %{title: "Revenue", outcome: "One paying customer."}, "g-1")
    task = created!("task", %{title: "Draft", progress: "todo"}, "t-1")

    {:ok, %{"head_seq" => linked, "result" => %{"relation_id" => link}}} =
      command("link", %{source: task, target: goal, type: "implements"}, "l-1")

    assert Projector.await(@fleet, run_id, linked) == linked
    assert [%{id: ^link}] = Graph.get_object!(@fleet, task, actor: @holder).relations

    removed = write!("unlink", %{relation_id: link}, "u-1")
    assert Projector.await(@fleet, run_id, removed) == removed

    patched = write!("patch", %{id: task, expected_version: 1, set: %{progress: "doing"}}, "p-1")
    assert Projector.await(@fleet, run_id, patched) == patched

    read = Graph.get_object!(@fleet, task, actor: @holder)
    assert read.relations == []
    assert read.object.version == 2

    assert Map.take(read.object.data, ["title", "progress"]) == %{
             "title" => "Draft",
             "progress" => "doing"
           }
  end

  test "a page that cannot move the cursor on leaves nothing of itself behind" do
    {head, _ids} = build_workspace()
    Graph.start_cursor!(%{fleet_id: @fleet, run_id: log_id()}, actor: @system)
    hold_after_cursor_read()

    test = self()
    copier = Task.async(fn -> hold_here(test, fn -> Projection.catch_up(@fleet) end) end)
    assert_receive {:held, pid}, 10_000

    # The cursor moves on while the copy holds its old place; the copy then
    # records and projects its page and cannot move the cursor past it.
    @fleet
    |> Graph.get_cursor!(actor: @system)
    |> Graph.advance_cursor!(%{applied_seq: 1}, actor: @system)

    send(pid, :go)

    assert {:error, _stale} = Task.await(copier, 30_000)
    assert head > 1
    assert tables()[Graph.Event] == []
    assert tables()[Graph.Object] == []
    assert [%{applied_seq: 1}] = tables()[Graph.Cursor]
  end

  test "of two copies running at once, the one that is behind rolls its page back" do
    {head, _ids} = build_workspace()
    run_id = log_id()
    Graph.start_cursor!(%{fleet_id: @fleet, run_id: run_id}, actor: @system)
    hold_after_cursor_read()

    test = self()
    behind = Task.async(fn -> hold_here(test, fn -> Projection.catch_up(@fleet) end) end)
    assert_receive {:held, pid}, 10_000

    assert Projection.catch_up(@fleet) == {:ok, {run_id, head}}
    copied = tables()

    send(pid, :go)
    assert {:error, _stale} = Task.await(behind, 30_000)
    assert tables() == copied
  end

  test "only the projector writes the read tables" do
    start_projector(catch_up_interval: 60_000)
    {head, _ids} = build_workspace()
    assert Projector.await(@fleet, log_id(), head) == head
    copied = tables()

    cursor = Graph.get_cursor!(@fleet, actor: @system)
    [event | _] = copied[Graph.Event]
    [object | _] = copied[Graph.Object]
    [relation | _] = copied[Graph.Relation]

    relations =
      Ash.Query.for_read(Graph.Relation, :with_ids, %{fleet_id: @fleet, ids: [relation.id]})

    for actor <- [
          nil,
          %Actors.Human{human_account_id: 1, wallet_addresses: [@wallet]},
          %Actors.Agent{
            wallet_address: @wallet,
            chain_id: 8453,
            verification_method: :eoa_recovery,
            audience: "keyfleet"
          }
        ] do
      # The writes of many rows at once report why they were refused.
      opts = [actor: actor, bulk_options: [return_errors?: true]]

      for write <- [
            fn -> Graph.record_events!([Map.drop(event, [:byte_size])], opts) end,
            fn -> Graph.project_objects!([object], opts) end,
            fn -> Graph.project_relations!([relation], opts) end,
            fn -> Graph.remove_relations!(relations, opts) end,
            fn ->
              Graph.start_cursor!(%{fleet_id: @other_fleet, run_id: "log_x"}, actor: actor)
            end,
            fn -> Graph.advance_cursor!(cursor, %{applied_seq: 0}, actor: actor) end,
            fn -> Graph.forget_cursor!(cursor, actor: actor) end
          ] do
        assert_raise Ash.Error.Forbidden, write
      end
    end

    assert tables() == copied
    assert Graph.get_cursor!(@other_fleet, actor: nil) == nil
  end

  test "a long backlog is read back in bounded pages, each change exactly once, loading only each page" do
    start_projector(catch_up_interval: 60_000)
    # Twenty thousand four-byte characters, the longest a note holds.
    long = String.duplicate("\u{1F600}", 20_000)

    for n <- 1..130, do: write!("create", note("Note #{n}"), "short-#{n}")

    head =
      Enum.reduce(1..8, 0, fn n, _ -> write!("create", note("Long #{n}", long), "long-#{n}") end)

    assert Projector.await(@fleet, log_id(), head) == head

    count_rows_read()
    pages = read_all(0, [])
    seqs = pages |> Enum.flat_map(& &1.events) |> Enum.map(& &1.seq)

    assert length(seqs) == 2 * 138
    assert seqs == Enum.sort(seqs) and seqs == Enum.uniq(seqs)
    assert Enum.all?(pages, &(length(&1.events) <= 500))
    assert Enum.any?(pages, &(length(&1.events) < 500 and &1.has_more))

    for page <- pages do
      assert length(page.events) == 1 or page_bytes(page.events) <= @page_bytes
      # The page's own rows, and at most one more to learn whether any follow.
      assert page.rows_read <= length(page.events) + 1
      assert ContractSchema.errors(Map.delete(page, :rows_read), "WorkspaceChanges") == []
    end

    assert List.last(pages).next_cursor == head

    {:ok, synced} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], 0, 0, @holder)
    assert {length(synced.graph.events), synced.graph.has_more} == {100, true}
    assert synced.next_poll_seconds == 0

    {:ok, caught_up} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], head, 0, @holder)
    assert {caught_up.graph.events, caught_up.graph.next_cursor} == {[], head}
    assert caught_up.next_poll_seconds in 15..30
  end

  test "an object read answers its first 200 links, oldest first, and says more exist" do
    start_projector(catch_up_interval: 60_000)
    {_head, ids} = build_workspace()

    links =
      for n <- 1..200 do
        evidence =
          created!(
            "evidence",
            %{title: "Interview #{n}", source_uri: "https://example.com/#{n}"},
            "e-#{n + 1}"
          )

        {:ok, %{"head_seq" => head, "result" => %{"relation_id" => id}}} =
          command("link", %{source: evidence, target: ids.task, type: "supports"}, "k-#{n}")

        {head, id}
      end

    {head, _id} = List.last(links)
    assert Projector.await(@fleet, log_id(), head) == head

    {:ok, read} = Graph.get_object(@fleet, ids.task, actor: @holder)
    assert {length(read.relations), read.relations_has_more} == {200, true}
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []
    # The task's link to the goal came first, so the newest link is left out.
    assert hd(read.relations).target == ids.goal

    assert Enum.map(tl(read.relations), & &1.id) ==
             links |> Enum.map(&elem(&1, 1)) |> Enum.take(199)
  end

  # The projector's own round asks the writer where its log stands, so it is
  # set well past the test's time limit: only a poll could reach the held
  # writer. The polls take most of a minute on a busy machine, so the test is
  # given two minutes, the longest the sandbox lends it a connection.
  @tag timeout: 120_000
  test "a thousand polls while the writer is held are all answered without reaching it" do
    start_projector(catch_up_interval: :timer.hours(1))
    {head, ids} = build_workspace()
    assert Projector.await(@fleet, log_id(), head) == head
    writer = writer()
    :sys.suspend(writer)
    on_exit(fn -> if Process.alive?(writer), do: :sys.resume(writer) end)

    # The case has one sandboxed connection, so polls sent at once would only
    # queue for it; they are made one after another.
    answers =
      for n <- 1..1_000,
          do: Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], rem(n, head), 0, @holder)

    assert Enum.all?(answers, &match?({:ok, %{graph: %{watermark: ^head}}}, &1))
    assert Enum.all?(answers, fn {:ok, synced} -> length(synced.graph.events) <= 100 end)

    goal = ids.goal

    assert {:ok, %{object: %{id: ^goal}, watermark: ^head}} =
             Graph.get_object(@fleet, goal, actor: @holder)

    assert Process.info(writer, :message_queue_len) == {:message_queue_len, 0}
    :sys.resume(writer)
  end

  # Two connections of their own: the read is held just after it learns how
  # far the tables reach, while the next page commits beside it.
  @tag :independent_connections
  test "a read answers the tables as they stood at its watermark while a page commits beside it" do
    Sandbox.unboxed_run(Repo, fn ->
      cursor =
        Graph.start_cursor!(%{fleet_id: @other_fleet, run_id: "log_snapshot"}, actor: @system)

      commit_page!(cursor, 1)
    end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        @other_fleet |> Graph.get_cursor!(actor: @system) |> Graph.forget_cursor!(actor: @system)
      end)
    end)

    hold_after_cursor_read()
    test = self()

    reader =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        # A Key's ownership is never deleted, so none is committed here: this
        # read is not authorized, as who may read is not what it tests.
        hold_here(test, fn ->
          Graph.list_changes(@other_fleet, %{after_seq: 0}, authorize?: false)
        end)
      end)

    assert_receive {:held, pid}, 10_000

    Sandbox.unboxed_run(Repo, fn ->
      @other_fleet |> Graph.get_cursor!(actor: @system) |> commit_page!(2)
    end)

    send(pid, :go)
    {:ok, read} = Task.await(reader, 30_000)

    assert {read.watermark, Enum.map(read.events, & &1.seq), read.next_cursor, read.has_more} ==
             {1, [1], 1, false}
  end

  test "an object last changed at its creation or its latest patch; linking and unlinking it leave that be" do
    start_projector(catch_up_interval: 60_000)
    run_id = log_id()
    goal = created!("goal", %{title: "Revenue", outcome: "One paying customer."}, "g-1")

    {:ok, %{"head_seq" => head, "result" => %{"id" => task}}} =
      command("create", %{type: "task", scope: "fleet", data: %{title: "Draft"}}, "t-1")

    assert Projector.await(@fleet, run_id, head) == head
    created = Graph.read_object!(@fleet, task, actor: @holder)
    assert {created.changed_seq, created.changed_at} == last_change(task)

    {:ok, %{"result" => %{"relation_id" => link}}} =
      command("link", %{source: task, target: goal, type: "implements"}, "l-1")

    unlinked = write!("unlink", %{relation_id: link}, "u-1")
    assert Projector.await(@fleet, run_id, unlinked) == unlinked
    assert Graph.read_object!(@fleet, task, actor: @holder) == created

    patched = write!("patch", %{id: task, expected_version: 1, set: %{progress: "doing"}}, "p-1")
    assert Projector.await(@fleet, run_id, patched) == patched
    read = Graph.read_object!(@fleet, task, actor: @holder)
    assert {read.changed_seq, read.changed_at} == last_change(task)
    assert read.changed_seq > unlinked
  end

  # The place and time of the latest creation or patch of the object.
  defp last_change(id) do
    tables()[Graph.Event]
    |> Enum.filter(
      &(&1.type in ~w(object.created patch.applied) and
          (&1.payload["id"] || &1.payload["target"]) == id)
    )
    |> Enum.max_by(& &1.seq)
    |> then(&{&1.seq, &1.timestamp})
  end

  # Four objects, three links (one removed again), a patch and an archive.
  # Answers the log's head and the goal's and task's ids.
  defp build_workspace do
    goal = created!("goal", %{title: "Revenue", outcome: "One paying customer."}, "g-1")

    service =
      created!(
        "service",
        %{
          title: "Briefs",
          customer: "Funds",
          problem: "Too many filings.",
          deliverable: "A weekly brief."
        },
        "s-1"
      )

    task = created!("task", %{title: "Draft", progress: "todo"}, "t-1")

    evidence =
      created!("evidence", %{title: "Interview", source_uri: "https://example.com/i"}, "e-1")

    write!("link", %{source: task, target: goal, type: "implements"}, "l-1")
    write!("link", %{source: evidence, target: service, type: "supports"}, "l-2")

    {:ok, %{"result" => %{"relation_id" => removed}}} =
      command("link", %{source: task, target: service, type: "implements"}, "l-3")

    write!("unlink", %{relation_id: removed}, "u-1")
    write!("patch", %{id: task, expected_version: 1, set: %{progress: "doing"}}, "p-1")
    head = write!("archive", %{id: goal, expected_version: 1}, "a-1")
    {head, %{goal: goal, task: task}}
  end

  # Copies a workspace, replaces the log file with a fresh one, writes to it
  # with `write`, and checks that the read tables, a changes read and a sync
  # now answer the new log alone. Answers the old and new heads.
  defp replace_log(%{tmp_dir: tmp_dir}, write) do
    start_projector(catch_up_interval: 60_000)
    {old_head, _ids} = build_workspace()
    old_run = log_id()
    assert Projector.await(@fleet, old_run, old_head) == old_head

    stop_supervised!(Keyfleet.Graph.Supervisor)
    start_writer(Path.join(tmp_dir, "fresh"))
    new_run = log_id()
    assert new_run != old_run
    new_head = write.(old_head)

    # What a write does once the log has answered: its wait ends only once
    # the new log is copied, never on the old log's place.
    assert Projector.await(@fleet, new_run, new_head) == new_head
    # A write the old log answered is not in the tables any more.
    assert Projector.await(@fleet, old_run, old_head) == 0

    titles = for object <- tables()[Graph.Object], do: object.data["title"]
    assert titles != [] and Enum.all?(titles, &String.starts_with?(&1, "Fresh"))
    assert tables()[Graph.Relation] == []
    assert [%{run_id: ^new_run, applied_seq: ^new_head}] = tables()[Graph.Cursor]

    {:ok, changes} = Graph.list_changes(@fleet, %{after_seq: 0, limit: 500}, actor: @holder)
    assert {changes.run_id, changes.watermark} == {new_run, new_head}

    {:ok, synced} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], old_head, 0, @holder)
    assert {synced.graph.run_id, synced.graph.watermark} == {new_run, new_head}

    {old_head, new_head}
  end

  # Fresh notes into the current log, from note `n` until its head reaches
  # `until`. Answers the log's head.
  defp write_notes(n, until) do
    head = write!("create", note("Fresh #{n}"), "fresh-#{n}")
    if head >= until, do: head, else: write_notes(n + 1, until)
  end

  # Copies the log's file and its write-ahead log from `from` into `to` while
  # the writer is held, so nothing reaches the host and neither file changes.
  # A host whose writer has stopped may still be closing them.
  defp back_up(from, to) do
    writer = writer()
    :sys.suspend(writer)
    File.mkdir_p!(to)

    for file <- ["#{@fleet}.sqlite", "#{@fleet}.sqlite-wal"],
        do: File.cp!(Path.join(from, file), Path.join(to, file))

    :sys.resume(writer)
  end

  defp created!(type, data, id) do
    {:ok, %{"result" => %{"id" => object_id}}} =
      command("create", %{type: type, scope: "fleet", data: data}, id)

    object_id
  end

  defp note(title, body \\ "Ship it."),
    do: %{type: "note", scope: "fleet", data: %{title: title, body: body}}

  defp write!(op, body, id) do
    {:ok, %{"head_seq" => head}} = command(op, body, id)
    head
  end

  defp command(op, body, id),
    do: Writer.command(@fleet, op, body, fn _within -> {:ok, stamped(id)} end)

  defp stamped(id) do
    %{
      id: id,
      principal: "member:8453:#{@contract}:17@3/agent:#{@wallet}",
      auth: %{
        key: %{chain_id: 8453, contract: @contract, token_id: 17},
        ownership_epoch: 3,
        kind: "agent",
        operator_wallet: @wallet,
        credential_ref: nil,
        checked_at: "2026-09-22T12:00:00Z",
        chain_block: nil
      },
      writable_scopes: ["fleet"]
    }
  end

  # One page of one event, committed with the cursor moved past it.
  defp commit_page!(cursor, seq) do
    Ash.transact(@tables, fn ->
      Graph.record_events!(
        [
          %{
            fleet_id: cursor.fleet_id,
            seq: seq,
            event_id: "evt_#{seq}",
            type: "object.created",
            actor: "keyfleet:gateway",
            timestamp: "2026-09-22T12:00:00Z",
            payload: %{}
          }
        ],
        actor: @system
      )

      Graph.advance_cursor!(cursor, %{applied_seq: seq}, actor: @system)
    end)
  end

  defp read_all(after_seq, pages) do
    {:ok, page} = Graph.list_changes(@fleet, %{after_seq: after_seq, limit: 500}, actor: @holder)
    page = Map.put(page, :rows_read, rows_read(0))
    pages = [page | pages]
    if page.has_more, do: read_all(page.next_cursor, pages), else: Enum.reverse(pages)
  end

  defp page_bytes(events),
    do: events |> Enum.map(&IO.iodata_length(Jason.encode_to_iodata!(&1))) |> Enum.sum()

  # Counts the rows each query of the events table hands back to this process.
  defp count_rows_read do
    id = {__MODULE__, :rows, make_ref()}
    :telemetry.attach(id, [:keyfleet, :repo, :query], &__MODULE__.report_rows/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def report_rows(_event, _measurements, %{source: "graph_events", result: result}, test) do
    with {:ok, %{num_rows: rows}} when self() == test <- result,
         do: send(test, {:rows_read, rows})
  end

  def report_rows(_event, _measurements, _metadata, _test), do: :ok

  defp rows_read(total) do
    receive do
      {:rows_read, rows} -> rows_read(total + rows)
    after
      0 -> total
    end
  end

  # A process running `hold_here/2` stops just after its first read of a
  # cursor, tells the test, and goes on when the test sends `:go`.
  defp own_key! do
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: @system
    )
  end

  defp hold_after_cursor_read do
    id = {__MODULE__, :hold, make_ref()}
    :telemetry.attach(id, [:keyfleet, :repo, :query], &__MODULE__.hold/4, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def hold(_event, _measurements, %{source: "graph_cursors"}, _config) do
    case Process.delete(:hold_after_cursor_read) do
      nil ->
        :ok

      test ->
        send(test, {:held, self()})
        receive do: (:go -> :ok)
    end
  end

  def hold(_event, _measurements, _metadata, _config), do: :ok

  defp hold_here(test, work) do
    Process.put(:hold_after_cursor_read, test)
    work.()
  end

  # Every row of every read table, in a fixed order.
  defp tables do
    Map.new(@tables, fn resource ->
      names = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
      {resource, resource |> Repo.all() |> Enum.map(&Map.take(&1, names)) |> Enum.sort()}
    end)
  end

  defp await_head(run_id, head) do
    receive do
      {:graph_head, @fleet, ^run_id, watermark} when watermark >= head -> watermark
      {:graph_head, @fleet, _run_id, _watermark} -> await_head(run_id, head)
    after
      10_000 -> flunk("the read tables never reached #{head}")
    end
  end

  defp log_id do
    {:ok, %{"result" => %{"run_id" => run_id}}} = Writer.request(@fleet, "hello", %{})
    run_id
  end

  defp start_writer(data_dir) do
    start_supervised!(
      {Keyfleet.Graph.Supervisor,
       fleets: [@fleet],
       data_dir: data_dir,
       reply_timeout: 5_000,
       hello_timeout: 30_000,
       restart_min: 20,
       restart_max: 200}
    )

    await_ready()
  end

  defp start_projector(opts),
    do:
      start_supervised!(
        {Keyfleet.Graph.Projectors, [fleets: [@fleet], projection_wait: 30_000] ++ opts}
      )

  defp writer do
    [{pid, _timeout}] = Registry.lookup(Keyfleet.Graph.Registry, @fleet)
    pid
  end

  defp await_ready(attempts \\ 750) do
    case Writer.request(@fleet, "hello", %{}) do
      {:ok, _hello} ->
        :ok

      {:error, _reason} when attempts > 0 ->
        Process.sleep(20)
        await_ready(attempts - 1)
    end
  end
end
