defmodule KeyFleet.Graph.WriterTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Graph.Writer

  @moduletag :tmp_dir

  @fleets KeyFleet.Fleets.catalog_ids()
  @wallet "0x" <> String.duplicate("a1", 20)
  @contract "0x" <> String.duplicate("b2", 20)
  @note %{type: "note", scope: "fleet", data: %{title: "Plan", body: "Ship the first service."}}

  setup %{tmp_dir: tmp_dir} do
    {:ok,
     tmp_dir: tmp_dir, marker: Path.join(tmp_dir, "hung"), data_dir: Path.join(tmp_dir, "graph")}
  end

  test "a host killed mid-command leaves it indeterminate; the writer replaces the host and the retry replays",
       ctx do
    start_graph(ctx, @fleets, python: hooked_python(ctx.tmp_dir))
    [fleet | others] = @fleets
    writer = writer(fleet)
    await_ready(fleet)

    pending =
      Task.async(fn -> Writer.command(fleet, "create", @note, authorized("hang-after-1")) end)

    shell_kill(await_marker(ctx.marker))

    assert Task.await(pending, 15_000) == {:error, :indeterminate}
    await_ready(fleet)
    assert writer(fleet) == writer

    assert {:ok, %{"replayed" => true, "result" => %{"id" => "note#1", "version" => 1}}} =
             Writer.command(fleet, "create", @note, authorized("hang-after-1"))

    for other <- others do
      assert {:ok, _hello} = Writer.request(other, "hello", %{})
    end
  end

  test "a host that stops answering inside its commit is killed at the deadline and the retry applies once",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
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
    before = {writer(fleet), writer(other), Process.whereis(KeyFleet.Graph.Registry)}

    for _ <- 1..10 do
      assert {:error, %{"code" => "bad_request"}} =
               Writer.request(fleet, "changes", %{after_seq: <<0xFF, 0xFE>>, limit: 1})

      assert {:error, %{"code" => "bad_request"}} =
               Writer.command(fleet, "create", %{type: <<0xFF>>}, authorized("c1"))
    end

    assert {writer(fleet), writer(other), Process.whereis(KeyFleet.Graph.Registry)} == before
    assert {:ok, _hello} = Writer.request(fleet, "hello", %{})

    assert {:ok, _hello} = Writer.request(other, "hello", %{})

    assert length(launches(ctx.tmp_dir)) == 2
  end

  test "a fleet whose host keeps crashing leaves the other fleets, the registry and the supervisors running",
       ctx do
    [crashing, healthy] = Enum.take(@fleets, 2)
    python = hooked_python(ctx.tmp_dir, crash_fleet: crashing)
    graph = start_graph(ctx, [crashing, healthy], python: python)
    await_ready(healthy)
    before = {writer(crashing), writer(healthy), Process.whereis(KeyFleet.Graph.Registry)}

    await(fn -> Enum.count(launches(ctx.tmp_dir), &(&1["fleet"] == crashing)) >= 8 end)

    assert Process.alive?(graph)
    assert {writer(crashing), writer(healthy), Process.whereis(KeyFleet.Graph.Registry)} == before
    assert Writer.request(crashing, "hello", %{}) == {:error, :unavailable}

    assert {:ok, _hello} = Writer.request(healthy, "hello", %{})
  end

  test "a host that exits while idle turns the next request into an error result and is replaced",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))
    await_ready(fleet)
    [%{"pid" => os_pid}] = launches(ctx.tmp_dir)

    shell_kill(Integer.to_string(os_pid))

    assert Writer.request(fleet, "hello", %{}) in [
             {:error, :indeterminate},
             {:error, :unavailable}
           ]

    await_ready(fleet)
  end

  describe "a writer whose host cannot start answers unavailable and recovers once the cause is gone" do
    test "when the interpreter is missing", ctx do
      python = Path.join(ctx.tmp_dir, "python")
      [fleet] = Enum.take(@fleets, 1)
      start_graph(ctx, [fleet], python: python)

      assert_unavailable_for_a_while(fleet)
      File.write!(python, "#!/bin/sh\nexec '#{python()}' \"$@\"\n")
      File.chmod!(python, 0o755)
      await_ready(fleet)
    end

    test "when the data directory cannot be created", ctx do
      parent = Path.join(ctx.tmp_dir, "volume")
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o500)
      on_exit(fn -> File.chmod(parent, 0o700) end)
      [fleet] = Enum.take(@fleets, 1)
      start_graph(ctx, [fleet], data_dir: Path.join(parent, "graph"))

      assert_unavailable_for_a_while(fleet)
      File.chmod!(parent, 0o700)
      await_ready(fleet)
    end

    test "when another host holds the fleet's lock", ctx do
      [fleet] = Enum.take(@fleets, 1)
      File.mkdir_p!(ctx.data_dir)
      holder = hold_lock(Path.join(ctx.data_dir, "#{fleet}.sqlite.lock"))
      start_graph(ctx, [fleet], python: hooked_python(ctx.tmp_dir))

      assert_unavailable_for_a_while(fleet)
      assert length(launches(ctx.tmp_dir)) >= 2
      Port.close(holder)
      await_ready(fleet)
    end
  end

  test "a burst of writer crashes past every restart limit inside the graph never leaves it down",
       ctx do
    [fleet, other] = Enum.take(@fleets, 2)
    top = start_as_application(ctx, [fleet, other])
    await_ready(fleet)
    await_ready(other)
    graph = Process.whereis(KeyFleet.Graph.Supervisor)

    Enum.reduce(1..40, nil, fn _, killed ->
      await(fn -> current_writer(fleet) not in [nil, killed] end)
      pid = current_writer(fleet)
      Process.exit(pid, :kill)
      pid
    end)

    await_ready(fleet)
    await_ready(other)
    assert Process.alive?(top)
    refute Process.whereis(KeyFleet.Graph.Supervisor) in [nil, graph]
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

  test "a check whose database read exits is answered unavailable, sends nothing and leaves the writer running",
       ctx do
    [fleet] = Enum.take(@fleets, 1)
    start_graph(ctx, [fleet])
    await_ready(fleet)
    writer = writer(fleet)

    pool_down = fn _within -> exit({:noproc, {DBConnection.Holder, :checkout, []}}) end

    assert Writer.command(fleet, "create", @note, pool_down) == {:error, :unavailable}
    assert writer(fleet) == writer

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] in ["object.created", "keyfleet.command"]))
  end

  test "a fleet with no running writer answers unavailable", ctx do
    assert Writer.request("fleet_without_graph", "hello", %{}) == {:error, :unavailable}

    start_graph(ctx, Enum.take(@fleets, 1))

    assert Writer.command("fleet_without_graph", "create", @note, authorized("c1")) ==
             {:error, :unavailable}
  end

  defp start_graph(ctx, fleets, opts \\ []) do
    start_supervised!({KeyFleet.Graph.Supervisor, graph_opts(ctx, fleets, opts)})
  end

  # The graph under a supervisor configured like the application's.
  defp start_as_application(ctx, fleets) do
    graph_child = {KeyFleet.Graph.Supervisor, graph_opts(ctx, fleets, [])}

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
        pairing_id: nil,
        credential_ref: nil,
        checked_at: "2026-09-22T12:00:00Z",
        chain_block: nil
      }
    }
  end

  defp writer(fleet) do
    [{pid, _timeout}] = Registry.lookup(KeyFleet.Graph.Registry, fleet)
    pid
  end

  # The registry itself is briefly gone while the graph supervisor restarts.
  defp current_writer(fleet) do
    case Registry.lookup(KeyFleet.Graph.Registry, fleet) do
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
