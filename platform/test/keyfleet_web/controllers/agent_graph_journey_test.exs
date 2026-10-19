defmodule KeyfleetWeb.AgentGraphJourneyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import KeyfleetWeb.RefusalHelpers
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.Chain
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys
  alias Keyfleet.Rooms

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @contract "0x" <> String.duplicate("7", 40)
  @levelled "fibonacci_cascade"
  @owners %{1 => "0x" <> String.duplicate("a", 40), 2 => "0x" <> String.duplicate("b", 40)}
  @goal %{
    title: "First paying customer",
    outcome: "One customer pays for a research brief within two weeks."
  }
  setup %{tmp_dir: tmp_dir} do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    ChainHelpers.deploy!(@fleet, %{manager_address: @contract})
    for {token_id, wallet} <- @owners, do: record_owner(token_id, 1, wallet)

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    Application.put_env(:keyfleet, :siwa_broker_url, server(:broker, &broker(&1, &2, secret)))
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))

    %{app: app, secret: secret, data_dir: Path.join(tmp_dir, "graph"), sandbox: owner}
  end

  test "two agents patching one version at once get one success and one conflict", c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    answers =
      [{ann, 1, "achieved"}, {bea, 2, "dropped"}]
      |> Enum.map(fn {agent, key, status} ->
        Task.async(fn ->
          {status,
           graph(c, agent, "patch", %{
             as_key: key,
             command_id: "race-#{key}",
             id: goal["id"],
             expected_version: 1,
             set: %{status: status}
           })}
        end)
      end)
      |> Task.await_many(15_000)

    assert answers |> Enum.map(fn {_status, answer} -> answer.status end) |> Enum.sort() ==
             [200, 409]

    {won_status, _won} = Enum.find(answers, fn {_status, answer} -> answer.status == 200 end)
    {_status, lost} = Enum.find(answers, fn {_status, answer} -> answer.status == 409 end)

    assert lost.body["error"]["code"] == "conflict"
    assert lost.body["error"]["details"]["current_version"] == 2
    assert lost.body["error"]["details"]["object"]["data"]["status"] == won_status
  end

  test "a key changing hands while its agent's write waits in line refuses that write, and its earlier edits keep their author",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    writer = writer()

    :sys.suspend(writer)

    waiting =
      Task.async(fn ->
        graph(c, ann, "patch", %{
          as_key: 1,
          command_id: "p-1",
          id: goal["id"],
          expected_version: 1,
          set: %{status: "achieved"}
        })
      end)

    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)
    record_owner(1, 2, "0x" <> String.duplicate("c", 40))
    :sys.resume(writer)

    refused = Task.await(waiting, 15_000)
    assert refused.status == 403
    assert refused.body["error"]["code"] == "not_a_key_holder"

    # Ann's shard ended with the sale, so Bea, holding a shard of Key 2, reads.
    object = graph(c, bea, "get", %{id: goal["id"]}).body["object"]
    assert object["version"] == 1
    assert object["data"]["status"] == "open"

    assert %{"key" => %{"token_id" => 1}, "ownership_epoch" => 1, "wallet" => wallet} =
             object["sys"]["created_by"]

    assert wallet == ann.address
  end

  test "a request cannot name its own author, standing or scope, or write server-owned fields",
       c do
    start_graph(c)
    [ann, _bea] = shard_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    create = %{as_key: 1, command_id: "f-1", type: "goal", scope: "fleet", data: @goal}

    for {field, value} <- [
          actor: "system",
          principal: "member:8453:#{@contract}:2@1/human:#{@owners[2]}",
          auth: %{kind: "human"},
          writable_scopes: ["fleet", "level:1"],
          sys: %{archived: true}
        ] do
      assert misfit?(graph(c, ann, "create", Map.put(create, field, value)))
    end

    for data <- [
          Map.put(@goal, :sys, %{scope: "fleet", created_by: %{}, archived: false}),
          Map.put(@goal, :created_by, %{wallet: @owners[2]}),
          Map.put(@goal, :approved, true)
        ] do
      refused = graph(c, ann, "create", %{create | data: data})
      assert {refused.status, refused.body["error"]["code"]} == {422, "forbidden_field"}
    end

    refused =
      graph(c, ann, "patch", %{
        as_key: 1,
        command_id: "f-2",
        id: goal["id"],
        expected_version: 1,
        set: %{sys: %{archived: true}}
      })

    assert {refused.status, refused.body["error"]["details"]} == {422, %{"fields" => ["sys"]}}

    events = graph(c, ann, "changes", %{}).body["events"]
    assert Enum.count(events, &(&1["type"] == "keyfleet.command")) == 1
  end

  # Costly failure: an agent reading the workspace back finds each item's
  # creator only as a wallet, so it can't check the name the fleet's pages
  # show beside the Key (Grok Bot, 19 October 2026).
  test "a workspace read names each agent behind what it answers, by the wallet its change carries",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    patched =
      graph(c, bea, "patch", %{
        as_key: 2,
        command_id: "p-1",
        id: goal["id"],
        expected_version: 1,
        set: %{status: "achieved"}
      })

    assert patched.status == 200

    read = graph(c, bea, "get", %{id: goal["id"]}).body
    assert read["agents"] == %{ann.address => "Ann"}
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []

    changes = graph(c, ann, "changes", %{}).body
    assert changes["agents"] == %{ann.address => "Ann", bea.address => "Bea"}
    assert ContractSchema.errors(changes, "WorkspaceChanges") == []

    actors = Map.new(changes["events"], &{&1["type"], &1["actor"]})
    assert String.ends_with?(actors["object.created"], "/agent:" <> ann.address)
    assert String.ends_with?(actors["patch.applied"], "/agent:" <> bea.address)
  end

  test "an agent joins a goal to follow it: the goal names who joined, and the agent's sync lists it",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    joined = graph(c, bea, "join", %{as_key: 2, command_id: "j-1", id: goal["id"]})
    assert joined.status == 200
    assert joined.body["result"] == %{"id" => goal["id"], "version" => 2}
    again = graph(c, bea, "join", %{as_key: 2, command_id: "j-2", id: goal["id"]})
    assert again.body["result"] == %{"id" => goal["id"], "version" => 2}

    read = graph(c, ann, "get", %{id: goal["id"]}).body

    assert [%{"key" => %{"token_id" => 2}, "kind" => "agent"} = member] =
             read["object"]["sys"]["joined"]

    assert member["wallet"] == bea.address
    assert read["agents"] == %{ann.address => "Ann", bea.address => "Bea"}
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []

    synced = sync(c, bea)
    assert [%{"id" => id, "status" => "open", "version" => 2}] = synced["yours"]["goals"]
    assert id == goal["id"]
    assert ContractSchema.errors(synced, "FleetSync") == []
    assert sync(c, ann)["yours"]["goals"] == []

    task =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        type: "task",
        data: %{title: "Draft"}
      })

    assert graph(c, ann, "join", %{as_key: 1, command_id: "j-3", id: task["id"]}).status == 422

    left = graph(c, bea, "leave", %{as_key: 2, command_id: "l-1", id: goal["id"]})
    assert left.body["result"] == %{"id" => goal["id"], "version" => 3}
    assert sync(c, bea)["yours"]["goals"] == []
  end

  # Syndicate keys other suites commit outside the sandbox would count as
  # sold, so the level tests run on the Cascade fleet.
  test "a key writes the fleet and its own level, and a later level once all its keys are sold",
       c do
    sell_levelled(1..3)
    start_graph(c, fleets: [@fleet, @levelled])
    [ann, cal] = shard_levelled(c, [{"Ann", 1}, {"Cal", 3}])

    # Key 1 is in level 1. Key 3 opens level 2, whose keys run from 3 to 5.
    first = write!(c, ann, "create", level_goal(1, "a-1", "level:1"), @levelled)
    second = write!(c, cal, "create", level_goal(3, "c-1", "level:2"), @levelled)
    assert scope_of(c, ann, first) == "level:1"
    assert scope_of(c, ann, second) == "level:2"

    for {agent, key, scope} <- [{cal, 3, "level:1"}, {ann, 1, "level:2"}, {cal, 3, "level:3"}] do
      assert_forbidden_scope(
        graph(c, agent, "create", level_goal(key, "x-#{key}", scope), @levelled),
        scope
      )
    end

    # Four of level 2's five keys sold does not open it; the fifth does.
    sell_levelled(4..4)

    assert_forbidden_scope(
      graph(c, ann, "create", level_goal(1, "a-2", "level:2"), @levelled),
      "level:2"
    )

    sell_levelled(5..5)
    opened = write!(c, ann, "create", level_goal(1, "a-3", "level:2"), @levelled)
    assert scope_of(c, ann, opened) == "level:2"

    # The next level waits for its own keys, and an earlier level stays closed.
    assert_forbidden_scope(
      graph(c, ann, "create", level_goal(1, "a-4", "level:3"), @levelled),
      "level:3"
    )

    assert_forbidden_scope(
      graph(c, cal, "create", level_goal(3, "c-2", "level:1"), @levelled),
      "level:1"
    )

    assert length(commands(c, ann, @levelled)) == 3

    # While the fleet's key ownership is not fresh, no level is written.
    ChainHelpers.seed_cursor!(@levelled, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    refused = graph(c, cal, "create", level_goal(3, "c-3", "level:2"), @levelled)
    assert {refused.status, refused.body["error"]["code"]} == {503, "ownership_refreshing"}
    assert length(logged_commands(@levelled)) == 3
  end

  test "an object in a level a key may not write cannot be linked, changed, archived or unlinked by it",
       c do
    sell_levelled(1..3)
    start_graph(c, fleets: [@fleet, @levelled])
    [ann, cal] = shard_levelled(c, [{"Ann", 1}, {"Cal", 3}])
    task = %{type: "task", data: %{title: "Draft the brief"}}

    open = write!(c, ann, "create", Map.merge(task, %{as_key: 1, command_id: "t-1"}), @levelled)

    closed =
      write!(
        c,
        cal,
        "create",
        Map.merge(task, %{as_key: 3, command_id: "t-2", scope: "level:2"}),
        @levelled
      )

    for {source, target} <- [{open, closed}, {closed, open}] do
      link = %{
        as_key: 1,
        command_id: "l-#{source["id"]}",
        source: source["id"],
        target: target["id"],
        type: "depends_on"
      }

      assert_forbidden_scope(graph(c, ann, "link", link, @levelled), "level:2")
    end

    link = %{
      as_key: 3,
      command_id: "l-1",
      source: open["id"],
      target: closed["id"],
      type: "depends_on"
    }

    linked = graph(c, cal, "link", link, @levelled)
    assert linked.status == 200
    relation_id = linked.body["result"]["relation_id"]

    for {op, body} <- [
          {"unlink", %{relation_id: relation_id}},
          {"patch", %{id: closed["id"], expected_version: 1, set: %{progress: "doing"}}},
          {"archive", %{id: closed["id"], expected_version: 1}}
        ] do
      body = Map.merge(%{as_key: 1, command_id: "x-#{op}"}, body)
      assert_forbidden_scope(graph(c, ann, op, body, @levelled), "level:2")
    end

    # Not even a key that writes the level can move an object out of it.
    for {set, n} <- Enum.with_index([%{sys: %{scope: "fleet"}}, %{scope: "fleet"}]) do
      patch = %{as_key: 3, command_id: "s-#{n}", id: closed["id"], expected_version: 1, set: set}
      refused = graph(c, cal, "patch", patch, @levelled)
      assert {refused.status, refused.body["error"]["code"]} == {422, "forbidden_field"}
    end

    read = graph(c, ann, "get", %{id: closed["id"]}, @levelled).body
    assert {read["object"]["version"], read["object"]["sys"]["scope"]} == {1, "level:2"}
    assert [%{"id" => ^relation_id}] = read["relations"]
    assert length(commands(c, ann, @levelled)) == 3
  end

  test "a wallet that neither owns nor holds a shard of the key it names is refused and nothing is written",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    stranger = join(c, "Stranger")

    for {agent, key} <- [{bea, 1}, {stranger, 1}, {ann, 3}] do
      refused =
        graph(c, agent, "create", %{
          as_key: key,
          command_id: "x-#{key}",
          type: "goal",
          scope: "fleet",
          data: @goal
        })

      assert {refused.status, refused.body["error"]["code"]} == {403, "not_a_key_holder"}
    end

    assert logged_commands() == []

    # Nor may it read the workspace: that needs a Key or a shard of one.
    for {op, input} <- [{"changes", %{}}, {"get", %{id: "goal#1"}}] do
      read = graph(c, stranger, op, input)
      assert {read.status, read.body["error"]["code"]} == {403, "workspace_members_only"}
      assert ContractSchema.errors(read.body, "WorkspaceError") == []
    end
  end

  test "a write whose outcome never came back says so, and its retry applies it once", c do
    start_graph(c, reply_timeout: 1_000)
    [ann, _bea] = shard_agents(c)
    create = %{as_key: 1, command_id: "g-1", type: "goal", scope: "fleet", data: @goal}

    # A host that stops answering: its outcome is unknown until it is replaced.
    host_pid = host_os_pid()
    {_, 0} = System.cmd("/bin/sh", ["-c", ~s(kill -STOP "$0"), host_pid])

    {lost, log} =
      with_log(fn ->
        lost = graph(c, ann, "create", create)
        await(fn -> match?({:ok, _}, Writer.request(@fleet, "hello", %{})) end)
        lost
      end)

    assert lost.status == 503
    assert lost.body["error"]["code"] == "indeterminate"
    assert lost.body["error"]["details"] == %{"retry_same_command_id" => true}

    assert Regex.scan(~r/graph host for \S+ stopped: .+$/m, log) ==
             [["graph host for #{@fleet} stopped: :reply_timeout"]]

    retried = graph(c, ann, "create", create)
    assert retried.status == 200
    assert retried.body["result"] == %{"id" => "goal#1", "version" => 1}
    assert graph(c, ann, "create", create).body["replayed"] == true
  end

  test "a write whose ownership cannot be read at its turn is answered unavailable and nothing is written",
       c do
    start_graph(c)
    [ann, _bea] = shard_agents(c)
    writer = writer()

    :sys.suspend(writer)
    waiting = Task.async(fn -> graph(c, ann, "create", goal_command("g-1")) end)
    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)

    # Only the sandbox's owner may reach the database now, so the writer's
    # ownership reads fail when the write's turn comes, and the site notes why.
    Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual)

    {refused, log} =
      with_log(fn ->
        :sys.resume(writer)
        Task.await(waiting, 15_000)
      end)

    Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, {:shared, c.sandbox})

    assert log =~
             "graph write for #{@fleet} not sent: its ownership check failed: " <>
               "** (DBConnection.OwnershipError) cannot find ownership process for"

    refute log =~ "Unknown Error"
    assert {refused.status, refused.body["error"]["code"]} == {503, "graph_unavailable"}
    assert refused.body["error"]["hint"] =~ "Nothing was written"

    # Leaving manual mode rolled the sandbox back, so the log itself shows
    # that nothing was written.
    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] == "keyfleet.command"))
    assert Process.alive?(writer)
  end

  test "key ownership going stale while a write waits in line refuses that write at its turn",
       c do
    start_graph(c)
    [ann, _bea] = shard_agents(c)
    writer = writer()

    :sys.suspend(writer)
    waiting = Task.async(fn -> graph(c, ann, "create", goal_command("g-1")) end)
    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    :sys.resume(writer)

    refused = Task.await(waiting, 15_000)
    assert {refused.status, refused.body["error"]["code"]} == {503, "ownership_refreshing"}
    assert logged_commands() == []
  end

  test "a wallet that holds no key is refused without waiting for the workspace", c do
    start_graph(c)
    stranger = join(c, "Stranger")
    writer = writer()

    :sys.suspend(writer)
    refused = graph(c, stranger, "create", goal_command("x-1"))
    assert Process.info(writer, :message_queue_len) == {:message_queue_len, 0}
    :sys.resume(writer)

    assert {refused.status, refused.body["error"]["code"]} == {403, "not_a_key_holder"}
    assert logged_commands() == []
  end

  test "after a key changes hands, the new owner's agent writes as that key under its new epoch",
       c do
    start_graph(c)
    [_ann, _bea] = shard_agents(c)
    new_owner = "0x" <> String.duplicate("c", 40)
    record_owner(1, 2, new_owner)
    cal = join(c, "Cal")
    shard(cal, 1)

    goal = write!(c, cal, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    assert %{"ownership_epoch" => 2, "wallet" => wallet} =
             graph(c, cal, "get", %{id: goal["id"]}).body["object"]["sys"]["created_by"]

    assert wallet == cal.address
    assert [command] = commands(c, cal)
    assert command["payload"]["principal"] == "member:8453:#{@contract}:1@2/agent:#{cal.address}"
    assert [stamp] = logged_commands()
    assert stamp["payload"]["auth"]["ownership_epoch"] == 2
  end

  test "a long note fits in one write, and a body past the write limit is refused as too large",
       c do
    start_graph(c)
    [ann, _bea] = shard_agents(c)
    # Twenty thousand characters, the most a note holds.
    note = %{title: "Interview transcript", body: String.duplicate("word ", 3_999) <> "done."}

    written =
      write!(c, ann, "create", %{as_key: 1, command_id: "n-1", type: "note", data: note})

    assert graph(c, ann, "get", %{id: written["id"]}).body["object"]["data"]["body"] ==
             note.body

    too_large = %{note | body: String.duplicate("word ", 10_010)}

    refused =
      graph(c, ann, "create", %{
        as_key: 1,
        command_id: "n-2",
        type: "note",
        scope: "fleet",
        data: too_large
      })

    assert {refused.status, refused.body} == {413, refused("request_too_large")}
    assert length(commands(c, ann)) == 1
  end

  defp start_graph(c, opts \\ []) do
    opts =
      Keyword.merge(
        [
          fleets: [@fleet],
          data_dir: c.data_dir,
          reply_timeout: 5_000,
          hello_timeout: 30_000,
          restart_min: 20,
          restart_max: 200
        ],
        opts
      )

    start_supervised!({Keyfleet.Graph.Supervisor, opts})

    for fleet <- opts[:fleets],
        do: await(fn -> match?({:ok, _}, Writer.request(fleet, "hello", %{})) end)

    # Writes ask the projector to copy them; with no rounds of its own during
    # a test, nothing else reaches the writer. Its first round is done once
    # it answers.
    start_supervised!({Keyfleet.Graph.Projectors, [catch_up_interval: 60_000] ++ opts})
    for fleet <- opts[:fleets], do: Projector.await(fleet, log_id(fleet), 0)
  end

  defp log_id(fleet) do
    {:ok, %{"result" => %{"run_id" => run_id}}} = Writer.request(fleet, "hello", %{})
    run_id
  end

  # The Cascade fleet deployed and fresh, with these keys sold.
  defp sell_levelled(token_ids) do
    if Chain.get_cursor!(@levelled) == nil do
      ChainHelpers.seed_cursor!(@levelled)
      ChainHelpers.deploy!(@levelled)
    end

    for token_id <- token_ids, do: record_owner(token_id, 1, owner_wallet(token_id), @levelled)
  end

  # One agent for each named Cascade key, holding a shard its owner issued.
  defp shard_levelled(c, names_and_keys) do
    for {name, token_id} <- names_and_keys do
      agent = join(c, name)
      shard(agent, token_id, @levelled)
      agent
    end
  end

  defp owner_wallet(token_id),
    do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  defp level_goal(token_id, command_id, scope),
    do: %{as_key: token_id, command_id: command_id, type: "goal", scope: scope, data: @goal}

  defp scope_of(c, agent, %{"id" => id}),
    do: graph(c, agent, "get", %{id: id}, @levelled).body["object"]["sys"]["scope"]

  defp assert_forbidden_scope(refused, scope) do
    assert {refused.status, refused.body["error"]["code"], refused.body["error"]["details"]} ==
             {403, "forbidden_scope", %{"scope" => scope}}
  end

  defp writer do
    [{pid, _timeout}] = Registry.lookup(Keyfleet.Graph.Registry, @fleet)
    pid
  end

  defp host_os_pid do
    {:os_pid, os_pid} = Port.info(:sys.get_state(writer()).host.port, :os_pid)
    Integer.to_string(os_pid)
  end

  # Two agents, each holding a shard of one of the fleet's two keys.
  defp shard_agents(c) do
    for {token_id, name} <- [{1, "Ann"}, {2, "Bea"}] do
      agent = join(c, name)
      shard(agent, token_id)
      agent
    end
  end

  defp shard(agent, token_id, fleet \\ @fleet),
    do: ChainHelpers.issue_shard!(fleet, token_id, agent.address)

  defp commands(c, agent, fleet \\ @fleet) do
    events = graph(c, agent, "changes", %{limit: 500}, fleet).body["events"]
    for %{"type" => "keyfleet.command"} = event <- events, do: event
  end

  # The command records as the log itself keeps them, authority stamp and all.
  defp logged_commands(fleet \\ @fleet) do
    {:ok, %{"result" => %{"events" => events}}} =
      Writer.request(fleet, "changes", %{after_seq: 0, limit: 500})

    for %{"type" => "keyfleet.command"} = event <- events, do: event
  end

  defp join(c, name) do
    {:ok, signer} = Siwa.LocalSigner.new()
    Keyfleet.PairingHelpers.pair_wallet!(signer.address)
    body = %{name: name, declared_harness: "local"}
    assert send_signed(c, signer, "POST", "/api/v1/agent/join/status", body).status == 200
    signer
  end

  defp record_owner(token_id, epoch, wallet, fleet \\ @fleet) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: wallet,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <>
            Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}/#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp goal_command(command_id),
    do: %{as_key: 1, command_id: command_id, type: "goal", scope: "fleet", data: @goal}

  # Creates, in the fleet scope unless the body names another, and answers
  # what was created.
  defp write!(c, agent, "create", body, fleet \\ @fleet) do
    body = Map.merge(%{type: "service", scope: "fleet"}, body)
    written = graph(c, agent, "create", body, fleet)
    assert written.status == 200
    assert written.body["replayed"] == false
    assert written.body["watermark"] >= written.body["head_seq"]
    assert ContractSchema.errors(written.body, "WorkspaceWrite") == []
    written.body["result"]
  end

  defp sync(c, agent) do
    body = %{
      rooms: [%{slug: "general", after_seq: 0}],
      graph: %{after_seq: 0},
      proposals: %{after_seq: 0},
      run: %{kind: "session"}
    }

    synced = send_signed(c, agent, "POST", "/api/v1/agent/fleets/#{@fleet}/sync", body)
    assert synced.status == 200
    synced.body
  end

  defp graph(c, agent, op, body, fleet \\ @fleet),
    do: send_signed(c, agent, "POST", "/api/v1/agent/fleets/#{fleet}/graph/#{op}", body)

  defp send_signed(c, signer, method, path, body),
    do: send_signed(c, signer, receipt(c, signer), method, path, body)

  defp send_signed(c, signer, receipt, method, path, body) do
    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{
          method: method,
          path: path,
          body: Jason.encode!(body),
          headers: %{"content-type" => "application/json"}
        },
        receipt,
        signer,
        secret: c.secret,
        audience: "keyfleet",
        wallet_audiences: ["keyfleet"]
      )

    Req.request!(
      method: method |> String.downcase() |> String.to_existing_atom(),
      url: c.app <> request.path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  # A wallet receipt whose key id is the signer's address.
  defp receipt(c, signer) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => signer.address,
          "chain_id" => 8453,
          "aud" => "keyfleet",
          "key_id" => signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: c.secret
      )

    receipt
  end

  defp broker(conn, _opts, secret) do
    {:ok, raw, conn} = read_body(conn)
    payload = Jason.decode!(raw)

    case Siwa.verify_authenticated_request(payload,
           secret: secret,
           audience: "keyfleet",
           wallet_audiences: ["keyfleet"]
         ) do
      {:ok, %{claims: claims, covered_components: covered}} ->
        answer(conn, 200, %{
          code: "http_envelope_valid",
          data: %{
            verified: true,
            walletAddress: claims["sub"],
            chainId: claims["chain_id"],
            verificationMethod: "eoa_recovery",
            keyId: claims["key_id"],
            receiptExpiresAt:
              DateTime.from_unix!(claims["exp"], :millisecond) |> DateTime.to_iso8601(),
            requiredHeaders: Siwa.required_authenticated_request_headers(payload["body_digest"]),
            requiredCoveredComponents:
              Siwa.required_authenticated_request_components(
                payload["headers"],
                payload["body_digest"]
              ),
            coveredComponents: covered,
            agentRegistration: nil,
            agentBook: nil,
            principal: %{
              kind: "wallet",
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              audience: claims["aud"]
            }
          }
        })

      {:error, _reason} ->
        answer(conn, 401, %{error: KeyfleetWeb.SignedAgentHelpers.refusal()})
    end
  end

  defp server(id, plug) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: id)
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp answer(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

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
