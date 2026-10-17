defmodule Keyfleet.Graph.WriterTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Graph.Writer

  @moduletag :tmp_dir

  @fleets Keyfleet.Fleets.catalog_ids()
  @wallet "0x" <> String.duplicate("a1", 20)
  @contract "0x" <> String.duplicate("b2", 20)
  @note %{type: "note", scope: "fleet", data: %{title: "Plan", body: "Ship the first service."}}

  # A host that stops is saved with the site's errors, from the writer's own
  # process.
  setup %{tmp_dir: tmp_dir} do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok,
     tmp_dir: tmp_dir, marker: Path.join(tmp_dir, "hung"), data_dir: Path.join(tmp_dir, "graph")}
  end

  test "a host killed mid-command leaves it indeterminate; the writer replaces the host and the retry replays",
       ctx do
    [fleet | others] = @fleets

    log =
      capture_host_failures(fn ->
        start_graph(ctx, @fleets, python: hooked_python(ctx.tmp_dir))
        writer = writer(fleet)
        await_ready(fleet)

        pending =
          Task.async(fn ->
            Writer.command(fleet, "create", @note, authorized("hang-after-1"))
          end)

        shell_kill(await_marker(ctx.marker))

        assert Task.await(pending, 15_000) == {:error, :indeterminate}
        await_ready(fleet)
        assert writer(fleet) == writer

        assert {:ok, %{"replayed" => true, "result" => %{"id" => "note#1", "version" => 1}}} =
                 Writer.command(fleet, "create", @note, authorized("hang-after-1"))

        for other <- others do
          assert {:ok, _hello} = Writer.request(other, "hello", %{})
        end
      end)

    assert host_stops(log) == ["graph host for #{fleet} stopped: {:host_exited, 137}"]
  end

  test "a host that stops answering inside its commit is killed at the deadline and the retry applies once",
       ctx do
    [fleet] = Enum.take(@fleets, 1)

    log =
      capture_host_failures(fn ->
        start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir), reply_timeout: 2_000)
        await_ready(fleet)

        assert Writer.command(fleet, "create", @note, authorized("hang-in-1")) ==
                 {:error, :indeterminate}

        refute ctx.marker |> File.read!() |> host_alive?()

        await_ready(fleet)

        assert {:ok, %{"replayed" => false, "result" => %{"id" => "note#1", "version" => 1}}} =
                 Writer.command(fleet, "create", @note, authorized("hang-in-1"))

        assert {:ok, %{"replayed" => true}} =
                 Writer.command(fleet, "create", @note, authorized("hang-in-1"))

        assert {:ok, %{"result" => %{"events" => events}}} =
                 Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

        assert Enum.count(events, &(&1["type"] == "object.created")) == 1
      end)

    assert host_stops(log) == ["graph host for #{fleet} stopped: :reply_timeout"]
  end

  test "a host starts isolated, from a fixed directory, with none of the application's environment",
       ctx do
    System.put_env("KEYFLEET_GRAPH_TEST_SECRET", "must-not-reach-the-host")
    on_exit(fn -> System.delete_env("KEYFLEET_GRAPH_TEST_SECRET") end)
    [fleet] = Enum.take(@fleets, 1)

    start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))
    await_ready(fleet)

    assert [%{"env" => env, "cwd" => "/", "argv" => ["-I", "-m", "keyfleet_graph" | _]}] =
             launches(ctx.tmp_dir)

    # macOS adds its text-encoding variable to every process it starts.
    assert env -- ["__CF_USER_TEXT_ENCODING"] == ["LANG"]
  end

  test "a body the host cannot parse is refused and the same host keeps serving", ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))
    await_ready(fleet)
    deep = Enum.reduce(1..10_000, [], fn _, inner -> [inner] end)

    assert {:error, %{"code" => "bad_request"}} =
             Writer.request(fleet, "changes", %{after_seq: deep, limit: 1})

    assert {:error, %{"code" => "bad_request"}} =
             Writer.request(fleet, "changes", %{after_seq: 2 ** 70, limit: 1})

    assert {:error, %{"code" => "bad_request", "message" => "the request is larger than 1 MiB"}} =
             Writer.request(fleet, "changes", %{
               after_seq: String.duplicate("a", 2_000_000),
               limit: 1
             })

    assert {:ok, _hello} = Writer.request(fleet, "hello", %{})
    assert length(launches(ctx.tmp_dir)) == 1
  end

  test "a burst of bodies JSON cannot express is refused in the caller and leaves every writer and host running",
       ctx do
    [fleet, other] = Enum.take(@fleets, 2)
    start_graph(ctx, [fleet, other], python: hooked_python(ctx.tmp_dir))
    await_ready(fleet)
    await_ready(other)
    before = {writer(fleet), writer(other), Process.whereis(Keyfleet.Graph.Registry)}

    for _ <- 1..10 do
      assert {:error, %{"code" => "bad_request"}} =
               Writer.request(fleet, "changes", %{after_seq: <<0xFF, 0xFE>>, limit: 1})

      assert {:error, %{"code" => "bad_request"}} =
               Writer.command(fleet, "create", %{type: <<0xFF>>}, authorized("c1"))
    end

    assert {writer(fleet), writer(other), Process.whereis(Keyfleet.Graph.Registry)} == before
    assert {:ok, _hello} = Writer.request(fleet, "hello", %{})

    assert {:ok, _hello} = Writer.request(other, "hello", %{})

    assert length(launches(ctx.tmp_dir)) == 2
  end

  test "a fleet whose host keeps crashing leaves the other fleets, the registry and the supervisors running",
       ctx do
    [crashing, healthy] = Enum.take(@fleets, 2)
    python = hooked_python(ctx.tmp_dir, crash_fleet: crashing)

    log =
      capture_host_failures(fn ->
        graph = start_graph(ctx, [crashing, healthy], python: python)
        await_ready(healthy)
        before = {writer(crashing), writer(healthy), Process.whereis(Keyfleet.Graph.Registry)}

        await(fn -> Enum.count(launches(ctx.tmp_dir), &(&1["fleet"] == crashing)) >= 8 end)

        assert Process.alive?(graph)

        assert {writer(crashing), writer(healthy), Process.whereis(Keyfleet.Graph.Registry)} ==
                 before

        assert Writer.request(crashing, "hello", %{}) == {:error, :unavailable}

        assert {:ok, _hello} = Writer.request(healthy, "hello", %{})
      end)

    assert host_stops(log) == ["graph host for #{crashing} stopped: {:host_exited, 3}"]
  end

  test "a host that exits while idle turns the next request into an error result and is replaced",
       ctx do
    [fleet] = Enum.take(@fleets, 1)

    log =
      capture_host_failures(fn ->
        start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))
        await_ready(fleet)
        [%{"pid" => os_pid}] = launches(ctx.tmp_dir)

        shell_kill(Integer.to_string(os_pid))

        assert Writer.request(fleet, "hello", %{}) in [
                 {:error, :indeterminate},
                 {:error, :unavailable}
               ]

        await_ready(fleet)
      end)

    assert host_stops(log) == ["graph host for #{fleet} stopped: {:host_exited, 137}"]
  end

  describe "a writer whose host cannot start answers unavailable and recovers once the cause is gone" do
    test "when the interpreter is missing", ctx do
      python = Path.join(ctx.tmp_dir, "python")
      [fleet] = Enum.take(@fleets, 1)

      log =
        capture_host_failures(fn ->
          start_graph(ctx, [fleet], python: python)

          assert_unavailable_for_a_while(fleet)
          File.write!(python, "#!/bin/sh\nexec '#{python()}' \"$@\"\n")
          File.chmod!(python, 0o755)
          await_ready(fleet)
        end)

      assert host_stops(log) == ["graph host for #{fleet} stopped: {:start_failed, :enoent}"]
    end

    test "when the data directory cannot be created", ctx do
      parent = Path.join(ctx.tmp_dir, "volume")
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o500)
      on_exit(fn -> File.chmod(parent, 0o700) end)
      [fleet] = Enum.take(@fleets, 1)

      log =
        capture_host_failures(fn ->
          start_graph(ctx, [fleet], data_dir: Path.join(parent, "graph"))

          assert_unavailable_for_a_while(fleet)
          File.chmod!(parent, 0o700)
          await_ready(fleet)
        end)

      assert host_stops(log) == ["graph host for #{fleet} stopped: {:start_failed, :eacces}"]
    end

    test "when another host holds the fleet's lock", ctx do
      [fleet] = Enum.take(@fleets, 1)
      File.mkdir_p!(ctx.data_dir)
      holder = hold_lock(Path.join(ctx.data_dir, "#{fleet}.sqlite.lock"))

      log =
        capture_host_failures(fn ->
          start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))

          assert_unavailable_for_a_while(fleet)
          assert length(launches(ctx.tmp_dir)) >= 2
          Port.close(holder)
          await_ready(fleet)
        end)

      assert host_stops(log) == ["graph host for #{fleet} stopped: {:host_exited, 75}"]
    end
  end

  test "a burst of writer crashes past every restart limit inside the graph never leaves it down",
       ctx do
    [fleet, other] = Enum.take(@fleets, 2)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        top = start_as_application(ctx, [fleet, other])
        await_ready(fleet)
        await_ready(other)
        graph = Process.whereis(Keyfleet.Graph.Supervisor)

        Enum.reduce(1..40, nil, fn _, killed ->
          await(fn -> current_writer(fleet) not in [nil, killed] end)
          pid = current_writer(fleet)
          Process.exit(pid, :kill)
          pid
        end)

        await_ready(fleet)
        await_ready(other)
        assert Process.alive?(top)
        refute Process.whereis(Keyfleet.Graph.Supervisor) in [nil, graph]
        stop_supervised!(:application)
      end)

    # A replacement host can start before the killed writer's host has let go
    # of its fleet's lock; it then exits and is started again.
    assert host_stops(log) --
             [
               "graph host for #{fleet} stopped: {:host_exited, 75}",
               "graph host for #{other} stopped: {:host_exited, 75}"
             ] == []
  end

  test "a write's authority is asked at its turn, and a refusal then sends nothing to the host",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet])
    await_ready(fleet)
    writer = writer(fleet)
    test = self()

    :sys.suspend(writer)

    pending =
      Task.async(fn ->
        Writer.command(fleet, "create", @note, fn within ->
          send(test, {:asked, self(), within})
          {:error, :key_changed_hands}
        end)
      end)

    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)
    refute_received {:asked, _pid, _within}
    :sys.resume(writer)

    assert Task.await(pending) == {:error, :key_changed_hands}
    check_timeout = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]
    assert_received {:asked, ^writer, ^check_timeout}

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] in ["object.created", "keyfleet.command"]))
  end

  test "a helper process a write's check links to the writer finishes without stopping it",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet])
    await_ready(fleet)
    writer = writer(fleet)

    check = fn _within ->
      :ok = fn -> :ok end |> Task.async() |> Task.await()
      {:ok, command("linked-1")}
    end

    assert {:ok, %{"replayed" => false}} = Writer.command(fleet, "create", @note, check)
    assert {:ok, _hello} = Writer.request(fleet, "hello", %{})
    assert writer(fleet) == writer
  end

  test "a check whose database read exits is answered unavailable, is logged, sends nothing and leaves the writer running",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet])
    await_ready(fleet)
    writer = writer(fleet)

    pool_down = fn _within -> exit({:noproc, {DBConnection.Holder, :checkout, []}}) end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Writer.command(fleet, "create", @note, pool_down) == {:error, :unavailable}
      end)

    assert log =~
             "graph write for #{fleet} not sent: its ownership check exited: " <>
               "exited in: DBConnection.Holder.checkout()"

    assert writer(fleet) == writer

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] in ["object.created", "keyfleet.command"]))
  end

  test "a check that raises is answered unavailable, is logged, sends nothing and leaves the writer running",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet])
    await_ready(fleet)
    writer = writer(fleet)

    faulty = fn _within -> raise ArgumentError, "no such level" end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Writer.command(fleet, "create", @note, faulty) == {:error, :unavailable}
      end)

    assert log =~ "graph write for #{fleet} not sent: its ownership check raised: no such level"
    assert writer(fleet) == writer

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] in ["object.created", "keyfleet.command"]))
  end

  test "one fleet's writes asking the most attention they may leave another fleet's plain writes as quick",
       ctx do
    [stormy, calm] = Enum.take(@fleets, 2)
    # Task 1 has 200 tasks waiting on it, each also waiting on the same 100
    # done tasks: every time it is marked done, the reactions read until the
    # work bound stops them.
    seed_waiting!(ctx.data_dir, stormy, 200, 100)
    start_graph(ctx, [stormy, calm])
    await_ready(stormy)
    await_ready(calm)

    before = Enum.map(1..50, &timed_note(calm, "before-#{&1}"))
    test = self()

    storm =
      Task.async(fn ->
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while([], fn n, asked ->
          progress = if rem(n, 2) == 1, do: "done", else: "doing"
          patch = %{id: "task#1", expected_version: n, set: %{progress: progress}}
          {:ok, reply} = Writer.command(stormy, "patch", patch, authorized("storm-#{n}"))
          asked = [Enum.count(reply["events"], &(&1["type"] == "keyfleet.attention")) | asked]
          if n == 2, do: send(test, :storming)

          receive do
            :stop -> {:halt, Enum.reverse(asked)}
          after
            0 -> {:cont, asked}
          end
        end)
      end)

    assert_receive :storming, 10_000
    during = Enum.map(1..200, &timed_note(calm, "during-#{&1}"))
    send(storm.pid, :stop)
    asked = Task.await(storm, 30_000)

    # The storm ran from before the first calm write until after the last, and
    # every round that marked task 1 done asked for all its bounds allow.
    assert length(asked) > 2
    assert asked |> Enum.take_every(2) |> Enum.uniq() == [19]

    # The calm fleet's writes answer as they did before the storm, well inside
    # the writer's reply budget.
    assert Enum.max(during) < 500_000
    assert median(during) <= median(before) * 3 + 20_000
  end

  test "a fleet with no running writer answers unavailable", ctx do
    assert Writer.request("fleet_without_graph", "hello", %{}) == {:error, :unavailable}

    start_graph(ctx, Enum.take(@fleets, 1))

    assert Writer.command("fleet_without_graph", "create", @note, authorized("c1")) ==
             {:error, :unavailable}
  end

  # Runs a case whose hosts fail on purpose, stopping its graph before the
  # capture ends so every stop a host logs is in the returned log.
  defp capture_host_failures(fun) do
    ExUnit.CaptureLog.capture_log(fn ->
      fun.()
      stop_supervised!(Keyfleet.Graph.Supervisor)
    end)
  end

  # Each different "graph host ... stopped" line in the log, once.
  defp host_stops(log) do
    ~r/graph host for \S+ stopped: .+$/m |> Regex.scan(log) |> List.flatten() |> Enum.uniq()
  end

  defp start_graph(ctx, fleets, opts \\ []) do
    start_supervised!({Keyfleet.Graph.Supervisor, graph_opts(ctx, fleets, opts)})
  end

  # The graph under a supervisor configured like the application's.
  defp start_as_application(ctx, fleets) do
    graph_child = {Keyfleet.Graph.Supervisor, graph_opts(ctx, fleets, [])}

    start_supervised!(%{
      id: :application,
      type: :supervisor,
      start: {Supervisor, :start_link, [[graph_child], [strategy: :one_for_one]]}
    })
  end

  defp graph_opts(ctx, fleets, opts) do
    Keyword.merge(
      [
        fleets: fleets,
        data_dir: ctx.data_dir,
        reply_timeout: 5_000,
        hello_timeout: 30_000,
        restart_min: 20,
        restart_max: 200
      ],
      opts
    )
  end

  # The real host behind a wrapper that records each launch (its pid, arguments,
  # working directory and environment names) and can be told to fail. A
  # `crash_fleet` host exits at once. A `hang-after-` command commits and then,
  # instead of replying, records the host's OS pid and sleeps: a crash between
  # commit and reply. A `hang-in-` command does the same with every event
  # appended but before COMMIT, once.
  defp hooked_python(tmp_dir, opts \\ []) do
    wrapper = Path.join(tmp_dir, "python")
    log = Path.join(tmp_dir, "launches")
    marker = Path.join(tmp_dir, "hung")

    File.write!(wrapper, """
    #!#{python()}
    import json, os, sys, time

    argv = sys.argv[1:]
    fleet = argv[argv.index("--fleet") + 1]
    with open(#{inspect(log)}, "a") as log:
        launch = {"fleet": fleet, "pid": os.getpid(), "argv": argv, "cwd": os.getcwd()}
        launch["env"] = sorted(os.environ)
        log.write(json.dumps(launch) + "\\n")
    if fleet == #{inspect(opts[:crash_fleet] || "")}:
        sys.exit(3)

    from keyfleet_graph import host

    def hang():
        if os.path.exists(#{inspect(marker)}):
            return
        with open(#{inspect(marker <> ".tmp")}, "w") as marker:
            marker.write(str(os.getpid()))
        os.replace(#{inspect(marker <> ".tmp")}, #{inspect(marker)})
        time.sleep(3600)

    _write, _settle = host.Host._write, host.Host._settle

    def write(self, request):
        self.hang_in_commit = request.command.id.startswith("hang-in-")
        reply = _write(self, request)
        if request.command.id.startswith("hang-after-") and reply["replayed"] is False:
            hang()
        return reply

    def settle(self):
        _settle(self)
        if getattr(self, "hang_in_commit", False):
            hang()

    host.Host._write, host.Host._settle = write, settle
    sys.argv = ["keyfleet_graph", *argv[3:]]
    from keyfleet_graph.__main__ import main
    main()
    """)

    File.chmod!(wrapper, 0o755)
    wrapper
  end

  defp python, do: Application.fetch_env!(:keyfleet, :graph)[:python]

  defp launches(tmp_dir) do
    case File.read(Path.join(tmp_dir, "launches")) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp hold_lock(path) do
    code = """
    import fcntl, sys
    lock = open(sys.argv[1], "a")
    fcntl.flock(lock, fcntl.LOCK_EX)
    print("held", flush=True)
    sys.stdin.read()
    """

    port = Port.open({:spawn_executable, python()}, [:binary, args: ["-c", code, path]])
    assert_receive {^port, {:data, "held\n"}}, 10_000
    port
  end

  defp authorized(id), do: fn _within -> {:ok, command(id)} end

  # Microseconds for one plain write to be answered.
  defp timed_note(fleet, id) do
    {micros, {:ok, %{"replayed" => false}}} =
      :timer.tc(fn -> Writer.command(fleet, "create", @note, authorized(id)) end)

    micros
  end

  defp median(values) do
    {_lower, [middle | _upper]} = values |> Enum.sort() |> Enum.split(div(length(values), 2))
    middle
  end

  # Writes a fleet's graph before its host starts: task 1, then `dependents`
  # tasks each waiting on task 1 and on the same `done` tasks already done.
  defp seed_waiting!(data_dir, fleet, dependents, done) do
    File.mkdir_p!(data_dir)

    code = """
    import sys
    from keyfleet_graph.host import Host

    fleet, db, dependents, done = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    actor = "member:8453:#{@contract}:17@3/agent:#{@wallet}"
    key = {"chain_id": 1, "contract": "#{@contract}", "token_id": 17}
    created_by = {"key": key, "ownership_epoch": 3, "kind": "agent", "wallet": "#{@wallet}"}
    sys_record = {"scope": "fleet", "created_by": created_by, "archived": False}
    host = Host(fleet, db)
    add = host.graph.add_object
    with host._transaction():
        blocker = add("task", {"title": "Blocker", "sys": sys_record}, actor=actor).id
        finished = [
            add("task", {"title": "Done", "progress": "done", "sys": sys_record}, actor=actor).id
            for _ in range(done)
        ]
        for n in range(dependents):
            task = add("task", {"title": f"Waiting {n}", "sys": sys_record}, actor=actor).id
            for target in (blocker, *finished):
                host.graph.add_relation(task, target, "depends_on", {}, actor=actor)
    while not host.runtime.run_quantum(max_queue_events=1_000, max_seconds=10.0).idle:
        pass
    host.graph.store.close()
    """

    db = Path.join(data_dir, "#{fleet}.sqlite")
    args = ["-c", code, fleet, db, to_string(dependents), to_string(done)]
    assert {_output, 0} = System.cmd(python(), args, stderr_to_stdout: true)
  end

  defp command(id) do
    token_id = 17

    %{
      id: id,
      principal: "member:8453:#{@contract}:#{token_id}@3/agent:#{@wallet}",
      auth: %{
        key: %{chain_id: 8453, contract: @contract, token_id: token_id},
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

  defp writer(fleet) do
    [{pid, _timeout}] = Registry.lookup(Keyfleet.Graph.Registry, fleet)
    pid
  end

  # The registry itself is briefly gone while the graph supervisor restarts.
  defp current_writer(fleet) do
    case Registry.lookup(Keyfleet.Graph.Registry, fleet) do
      [{pid, _timeout}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp await_ready(fleet),
    do: await(fn -> match?({:ok, _}, Writer.request(fleet, "hello", %{})) end)

  defp assert_unavailable_for_a_while(fleet) do
    for _ <- 1..10 do
      assert Writer.request(fleet, "hello", %{}) == {:error, :unavailable}
      Process.sleep(50)
    end
  end

  defp await_marker(marker) do
    await(fn -> File.exists?(marker) end)
    File.read!(marker)
  end

  # The same builtin the writer uses, so no kill executable is needed.
  defp shell_kill(os_pid), do: {_, 0} = System.cmd("/bin/sh", ["-c", ~s(kill -9 "$0"), os_pid])

  defp host_alive?(os_pid),
    do:
      match?(
        {_, 0},
        System.cmd("/bin/sh", ["-c", ~s(kill -0 "$0"), os_pid], stderr_to_stdout: true)
      )

  defp await(condition, attempts \\ 750) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("the condition never held")

      true ->
        Process.sleep(20)
        await(condition, attempts - 1)
    end
  end
end
