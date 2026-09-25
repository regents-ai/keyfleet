defmodule KeyfleetWeb.AgentGraphJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.Agents
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
  @service %{
    title: "Research briefs",
    customer: "Small funds",
    problem: "They cannot read every filing.",
    deliverable: "A weekly two-page brief."
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
    Rooms.bootstrap_rooms!()
    deploy(@fleet, @contract)
    for {token_id, wallet} <- @owners, do: record_owner(token_id, 1, wallet)

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    Application.put_env(:keyfleet, :siwa_broker_url, server(:broker, &broker(&1, &2, secret)))
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))

    %{app: app, secret: secret, data_dir: Path.join(tmp_dir, "graph"), sandbox: owner}
  end

  test "two agents build a goal and a service with tasks, evidence and links, each edit credited to its key",
       c do
    start_graph(c)
    [ann, bea] = pair_agents(c)

    posted =
      send_signed(c, ann, "POST", "/api/v1/agent/fleets/#{@fleet}/rooms/voting/messages/send", %{
        body: "Customer interview notes are in.",
        idempotency_key: "m-1"
      })

    assert posted.status == 201

    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    service = write!(c, bea, "create", %{as_key: 2, command_id: "s-1", data: @service})

    task =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        type: "task",
        data: %{title: "Draft the first brief", progress: "doing"}
      })

    evidence =
      write!(c, bea, "create", %{
        as_key: 2,
        command_id: "e-1",
        type: "evidence",
        data: %{title: "Interview", source_uri: "https://example.com/interview"}
      })

    # Saving a chat post to the workspace links the object back to it.
    note =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "n-1",
        type: "note",
        data: %{
          title: "Interview notes",
          body: "See the post.",
          discussion: [%{room: "voting", seq: 1}]
        }
      })

    for {agent, key, id, source, target, type} <- [
          {ann, 1, "l-1", task, goal, "implements"},
          {bea, 2, "l-2", evidence, service, "supports"},
          {bea, 2, "l-3", task, service, "implements"}
        ] do
      linked =
        graph(c, agent, "link", %{
          as_key: key,
          command_id: id,
          source: source["id"],
          target: target["id"],
          type: type
        })

      assert linked.status == 200
      assert %{"existing" => false, "relation_id" => "rel_" <> _} = linked.body["result"]
      assert ContractSchema.errors(linked.body, "WorkspaceWrite") == []
    end

    claimed =
      graph(c, bea, "patch", %{
        as_key: 2,
        command_id: "t-2",
        id: task["id"],
        expected_version: 1,
        set: %{assignee_key: 2, next_step: "Send it to the customer."}
      })

    assert claimed.status == 200
    assert claimed.body["result"] == %{"id" => task["id"], "version" => 2}
    assert claimed.body["watermark"] >= claimed.body["head_seq"]
    assert ContractSchema.errors(claimed.body, "WorkspaceWrite") == []

    read = graph(c, bea, "get", %{id: goal["id"]})
    assert read.status == 200
    assert ContractSchema.errors(read.body, "WorkspaceObjectView") == []
    assert read.body["object"]["data"]["title"] == "First paying customer"
    assert read.body["object"]["sys"]["created_by"]["key"]["token_id"] == 1
    assert read.body["object"]["sys"]["created_by"]["wallet"] == ann.address

    assert [%{"type" => "implements", "source" => source}] = read.body["relations"]
    assert source == task["id"]

    assert graph(c, ann, "get", %{id: note["id"]}).body["object"]["data"]["discussion"] ==
             [%{"room" => "voting", "seq" => 1}]

    # The same command again answers the original result and writes nothing.
    again =
      graph(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        type: "goal",
        scope: "fleet",
        data: @goal
      })

    assert again.status == 200
    assert again.body["replayed"] == true
    assert again.body["result"] == %{"id" => goal["id"], "version" => 1}

    # Anyone signed in may read the workspace; its changes name who did what.
    reader = join(c, "Reader")
    changes = graph(c, reader, "changes", %{after_seq: 0, limit: 500})
    assert changes.status == 200
    assert ContractSchema.errors(changes.body, "WorkspaceChanges") == []
    commands = for %{"type" => "keyfleet.command"} = event <- changes.body["events"], do: event

    assert length(commands) == 9
    [first | _] = commands

    assert first["payload"] == %{
             "principal" => "member:8453:#{@contract}:1@1/agent:#{ann.address}",
             "op" => "create",
             "result" => %{"id" => goal["id"], "version" => 1},
             "events" => first["payload"]["events"]
           }

    # The standing each write was made under stays in the log itself.
    [stamp | _] = logged_commands()
    [pairing] = Keys.my_pairings!(actor: agent_actor(ann))

    assert %{
             "key" => %{"chain_id" => 8453, "contract" => @contract, "token_id" => 1},
             "ownership_epoch" => 1,
             "kind" => "agent",
             "operator_wallet" => operator,
             "pairing_id" => pairing_id,
             "credential_ref" => "sha256:" <> digest,
             "chain_block" => 1_000
           } = stamp["payload"]["auth"]

    assert {operator, pairing_id} == {ann.address, pairing.id}
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "an agent that was away gets the workspace's edits and the chat it missed in one sync",
       c do
    start_graph(c)
    [ann, bea] = pair_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    left = sync(c, ann, %{"general" => 0, "voting" => 0}, 0)
    assert left.status == 200
    [general, voting] = left.body["rooms"]
    graph_cursor = left.body["graph"]["next_cursor"]
    assert graph_cursor == left.body["graph"]["watermark"]

    # Ann is away while Bea writes in the workspace and in the chat.
    posted =
      send_signed(c, bea, "POST", "/api/v1/agent/fleets/#{@fleet}/rooms/voting/messages/send", %{
        body: "The goal is done.",
        idempotency_key: "m-1"
      })

    assert posted.status == 201
    service = write!(c, bea, "create", %{as_key: 2, command_id: "s-1", data: @service})

    achieved =
      graph(c, bea, "patch", %{
        as_key: 2,
        command_id: "p-1",
        id: goal["id"],
        expected_version: 1,
        set: %{status: "achieved"}
      })

    assert achieved.status == 200

    back =
      sync(c, ann, %{"general" => general["cursor"], "voting" => voting["cursor"]}, graph_cursor)

    assert back.status == 200
    assert back.body["next_poll_seconds"] in 15..30
    assert [%{"messages" => []}, %{"messages" => [missed]}] = back.body["rooms"]
    assert missed["body"] == "The goal is done."

    missed_graph = back.body["graph"]
    assert ContractSchema.errors(missed_graph, "WorkspaceChanges") == []
    assert missed_graph["run_id"] == log_id()
    assert missed_graph["has_more"] == false
    assert missed_graph["watermark"] >= achieved.body["head_seq"]
    assert missed_graph["next_cursor"] == missed_graph["watermark"]

    changed =
      for %{"type" => type, "payload" => payload} <- missed_graph["events"],
          type != "keyfleet.command",
          do: {type, payload["object"]["id"] || payload["patch"]["target"]}

    assert changed == [{"object.created", service["id"]}, {"patch.applied", goal["id"]}]
  end

  test "while the workspace's writer is held, reads and syncs still answer", c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    writer = writer()
    :sys.suspend(writer)
    on_exit(fn -> if Process.alive?(writer), do: :sys.resume(writer) end)

    read = graph(c, ann, "get", %{id: goal["id"]})
    assert {read.status, read.body["object"]["version"]} == {200, 1}
    assert graph(c, ann, "changes", %{}).status == 200
    assert sync(c, ann, %{"general" => 0}, 0).status == 200

    assert Process.info(writer, :message_queue_len) == {:message_queue_len, 0}
    :sys.resume(writer)
  end

  test "a write made while the projectors are down is answered, and says its place is not known to be copied",
       c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    stop_supervised!(Keyfleet.Graph.Projectors)

    written = graph(c, ann, "create", goal_command("g-1"))
    assert written.status == 200
    assert {written.body["replayed"], written.body["watermark"]} == {false, 0}
    assert ContractSchema.errors(written.body, "WorkspaceWrite") == []
  end

  test "two agents patching one version at once get one success and one conflict", c do
    start_graph(c)
    [ann, bea] = pair_agents(c)
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

    assert lost.body["error"] == "conflict"
    assert lost.body["details"]["current_version"] == 2
    assert lost.body["details"]["object"]["data"]["status"] == won_status
  end

  test "a key changing hands while its agent's write waits in line refuses that write, and its earlier edits keep their author",
       c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
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
    assert refused.body["error"] == "not_a_key_holder"

    object = graph(c, ann, "get", %{id: goal["id"]}).body["object"]
    assert object["version"] == 1
    assert object["data"]["status"] == "open"

    assert %{"key" => %{"token_id" => 1}, "ownership_epoch" => 1, "wallet" => wallet} =
             object["sys"]["created_by"]

    assert wallet == ann.address
  end

  test "a request cannot name its own author, standing or scope, or write server-owned fields",
       c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    create = %{as_key: 1, command_id: "f-1", type: "goal", scope: "fleet", data: @goal}

    for {field, value} <- [
          actor: "system",
          principal: "member:8453:#{@contract}:2@1/human:#{@owners[2]}",
          auth: %{kind: "human"},
          writable_scopes: ["fleet", "level:1"],
          sys: %{archived: true}
        ] do
      assert graph(c, ann, "create", Map.put(create, field, value)).status == 401
    end

    for data <- [
          Map.put(@goal, :sys, %{scope: "fleet", created_by: %{}, archived: false}),
          Map.put(@goal, :created_by, %{wallet: @owners[2]}),
          Map.put(@goal, :approved, true)
        ] do
      refused = graph(c, ann, "create", %{create | data: data})
      assert {refused.status, refused.body["error"]} == {422, "forbidden_field"}
    end

    refused =
      graph(c, ann, "patch", %{
        as_key: 1,
        command_id: "f-2",
        id: goal["id"],
        expected_version: 1,
        set: %{sys: %{archived: true}}
      })

    assert {refused.status, refused.body["details"]} == {422, %{"fields" => ["sys"]}}

    events = graph(c, ann, "changes", %{}).body["events"]
    assert Enum.count(events, &(&1["type"] == "keyfleet.command")) == 1
  end

  # Syndicate keys other suites commit outside the sandbox would count as
  # sold, so the level tests run on the Cascade fleet.
  test "a key writes the fleet and its own level, and a later level once all its keys are sold",
       c do
    sell_levelled(1..3)
    start_graph(c, fleets: [@fleet, @levelled])
    [ann, cal] = pair_levelled(c, [{"Ann", 1}, {"Cal", 3}])

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
    assert {refused.status, refused.body["error"]} == {503, "ownership_refreshing"}
    assert length(commands(c, ann, @levelled)) == 3
  end

  test "an object in a level a key may not write cannot be linked, changed, archived or unlinked by it",
       c do
    sell_levelled(1..3)
    start_graph(c, fleets: [@fleet, @levelled])
    [ann, cal] = pair_levelled(c, [{"Ann", 1}, {"Cal", 3}])
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
      assert {refused.status, refused.body["error"]} == {422, "forbidden_field"}
    end

    read = graph(c, ann, "get", %{id: closed["id"]}, @levelled).body
    assert {read["object"]["version"], read["object"]["sys"]["scope"]} == {1, "level:2"}
    assert [%{"id" => ^relation_id}] = read["relations"]
    assert length(commands(c, ann, @levelled)) == 3
  end

  test "a Classic or Accelerant key writes the fleet scope and no level", c do
    unlevelled = ["fleet_tech_classic", "fleet_tech_accelerant"]

    for {fleet, n} <- Enum.with_index(unlevelled, 1) do
      ChainHelpers.seed_cursor!(fleet)
      deploy(fleet, "0x" <> String.duplicate("#{n}", 40))
      record_owner(1, 1, owner_wallet(1), fleet)
    end

    start_graph(c, fleets: [@fleet | unlevelled])
    dee = join(c, "Dee")

    for fleet <- unlevelled do
      pair(c, dee, 1, owner_wallet(1), fleet)
      assert write!(c, dee, "create", level_goal(1, "g-1", "fleet"), fleet)

      for scope <- ["level:1", "level:2"] do
        assert_forbidden_scope(
          graph(c, dee, "create", level_goal(1, "g-#{scope}", scope), fleet),
          scope
        )
      end

      assert length(commands(c, dee, fleet)) == 1
    end
  end

  test "a task marked done tells the tasks waiting on it, and new evidence asks for a review, in changes and in sync",
       c do
    start_graph(c)
    [ann, bea] = pair_agents(c)
    task = fn id, title -> %{as_key: 1, command_id: id, type: "task", data: %{title: title}} end
    blocker = write!(c, ann, "create", task.("t-1", "Find a customer"))
    waiting = write!(c, ann, "create", task.("t-2", "Write the brief"))

    evidence =
      write!(c, bea, "create", %{
        as_key: 2,
        command_id: "e-1",
        type: "evidence",
        data: %{title: "Call", source_uri: "https://example.com/call"}
      })

    link = %{
      as_key: 1,
      command_id: "l-1",
      source: waiting["id"],
      target: blocker["id"],
      type: "depends_on"
    }

    assert graph(c, ann, "link", link).status == 200
    cursor = sync(c, ann, %{"general" => 0}, 0).body["graph"]["next_cursor"]

    done = %{
      as_key: 1,
      command_id: "p-1",
      id: blocker["id"],
      expected_version: 1,
      set: %{progress: "done"}
    }

    assert graph(c, ann, "patch", done).status == 200

    review = %{
      as_key: 2,
      command_id: "l-2",
      source: evidence["id"],
      target: waiting["id"],
      type: "supports"
    }

    assert graph(c, bea, "link", review).status == 200

    changes = graph(c, bea, "changes", %{after_seq: cursor}).body
    synced = sync(c, ann, %{"general" => 0}, cursor).body["graph"]
    assert synced["events"] == changes["events"]

    for page <- [changes, synced] do
      assert ContractSchema.errors(page, "WorkspaceChanges") == []
    end

    [patched, unblocked, first_ledger, linked, reviewed, second_ledger] = changes["events"]
    log = changes["run_id"]
    assert Enum.map([patched, linked], & &1["type"]) == ["patch.applied", "relation.created"]

    assert [unblocked, reviewed] |> Enum.map(&Map.take(&1, ~w(type actor payload))) == [
             %{
               "type" => "keyfleet.attention",
               "actor" => "keyfleet:gateway",
               "payload" => %{
                 "kind" => "task_unblocked",
                 "object_id" => waiting["id"],
                 "cause" => %{"event_id" => patched["id"]},
                 "dedupe_key" => "#{log}:task_unblocked:#{waiting["id"]}:#{patched["id"]}"
               }
             },
             %{
               "type" => "keyfleet.attention",
               "actor" => "keyfleet:gateway",
               "payload" => %{
                 "kind" => "needs_review",
                 "object_id" => waiting["id"],
                 "cause" => %{"event_id" => linked["id"]},
                 "dedupe_key" => "#{log}:needs_review:#{waiting["id"]}:#{linked["id"]}"
               }
             }
           ]

    # Each write's command record names the notices it left alongside its change.
    assert first_ledger["payload"]["events"] == [patched["id"], unblocked["id"]]
    assert second_ledger["payload"]["events"] == [linked["id"], reviewed["id"]]

    # The same write again is answered from the record and asks nothing more.
    assert graph(c, ann, "patch", done).body["replayed"] == true
    assert graph(c, bea, "changes", %{after_seq: cursor}).body["events"] == changes["events"]
  end

  test "a wallet that does not run the key it names is refused and nothing is written", c do
    start_graph(c)
    [ann, bea] = pair_agents(c)
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

      assert {refused.status, refused.body["error"]} == {403, "not_a_key_holder"}
    end

    events = graph(c, stranger, "changes", %{}).body["events"]
    refute Enum.any?(events, &(&1["type"] == "keyfleet.command"))
  end

  test "while key ownership is not fresh, writes wait and reads carry on", c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))

    refused =
      graph(c, ann, "archive", %{
        as_key: 1,
        command_id: "a-1",
        id: goal["id"],
        expected_version: 1
      })

    assert {refused.status, refused.body["error"]} == {503, "ownership_refreshing"}

    read = graph(c, ann, "get", %{id: goal["id"]})
    assert read.status == 200
    assert read.body["object"]["sys"]["archived"] == false
  end

  test "an unknown fleet is not found, and a fleet whose workspace is down refuses writes but still reads",
       c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    goal = write!(c, ann, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})
    create = %{as_key: 1, command_id: "g-2", type: "goal", scope: "fleet", data: @goal}

    for {op, body} <- [{"get", %{id: goal["id"]}}, {"create", create}] do
      missing = send_signed(c, ann, "POST", "/api/v1/agent/fleets/hull_survey/graph/#{op}", body)
      assert {missing.status, missing.body["error"]} == {404, "fleet_unknown"}
    end

    stop_supervised!(Keyfleet.Graph.Supervisor)

    refused = graph(c, ann, "create", create)
    assert {refused.status, refused.body["error"]} == {503, "graph_unavailable"}

    read = graph(c, ann, "get", %{id: goal["id"]})
    assert {read.status, read.body["object"]["data"]["title"]} == {200, @goal.title}
    assert [_command] = commands(c, ann)

    absent = graph(c, ann, "get", %{id: "goal#9"})
    assert {absent.status, absent.body["error"]} == {404, "not_found"}
  end

  test "a write whose outcome never came back says so, and its retry applies it once", c do
    start_graph(c, reply_timeout: 1_000)
    [ann, _bea] = pair_agents(c)
    create = %{as_key: 1, command_id: "g-1", type: "goal", scope: "fleet", data: @goal}

    # A host that stops answering: its outcome is unknown until it is replaced.
    host_pid = host_os_pid()
    {_, 0} = System.cmd("/bin/sh", ["-c", ~s(kill -STOP "$0"), host_pid])

    lost = graph(c, ann, "create", create)
    assert lost.status == 503
    assert lost.body["error"] == "indeterminate"
    assert lost.body["details"] == %{"retry_same_command_id" => true}

    await(fn -> match?({:ok, _}, Writer.request(@fleet, "hello", %{})) end)

    retried = graph(c, ann, "create", create)
    assert retried.status == 200
    assert retried.body["result"] == %{"id" => "goal#1", "version" => 1}
    assert graph(c, ann, "create", create).body["replayed"] == true
  end

  test "a write whose ownership cannot be read at its turn is answered unavailable and nothing is written",
       c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    writer = writer()

    :sys.suspend(writer)
    waiting = Task.async(fn -> graph(c, ann, "create", goal_command("g-1")) end)
    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)

    # Only the sandbox's owner may reach the database now, so the writer's
    # ownership reads fail when the write's turn comes.
    Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual)
    :sys.resume(writer)
    refused = Task.await(waiting, 15_000)
    Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, {:shared, c.sandbox})

    assert {refused.status, refused.body["error"]} == {503, "graph_unavailable"}
    assert refused.body["message"] =~ "nothing was written"

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
    [ann, _bea] = pair_agents(c)
    writer = writer()

    :sys.suspend(writer)
    waiting = Task.async(fn -> graph(c, ann, "create", goal_command("g-1")) end)
    await(fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end)
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    :sys.resume(writer)

    refused = Task.await(waiting, 15_000)
    assert {refused.status, refused.body["error"]} == {503, "ownership_refreshing"}
    assert commands(c, ann) == []
  end

  test "a wallet that holds no key is refused without waiting for the workspace", c do
    start_graph(c)
    stranger = join(c, "Stranger")
    writer = writer()

    :sys.suspend(writer)
    refused = graph(c, stranger, "create", goal_command("x-1"))
    assert Process.info(writer, :message_queue_len) == {:message_queue_len, 0}
    :sys.resume(writer)

    assert {refused.status, refused.body["error"]} == {403, "not_a_key_holder"}
    assert commands(c, stranger) == []
  end

  test "after a key changes hands, the new owner's agent writes as that key under its new epoch",
       c do
    start_graph(c)
    [_ann, _bea] = pair_agents(c)
    new_owner = "0x" <> String.duplicate("c", 40)
    record_owner(1, 2, new_owner)
    cal = join(c, "Cal")
    pair(c, cal, 1, new_owner)

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
    [ann, _bea] = pair_agents(c)
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

    assert {refused.status, refused.body} == {413, %{"error" => "request_too_large"}}
    assert length(commands(c, ann)) == 1
  end

  test "a write's log entry names the credential that signed it, by digest", c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)
    receipt = receipt(c, ann)
    path = "/api/v1/agent/fleets/#{@fleet}/graph/create"

    assert send_signed(c, ann, receipt, "POST", path, goal_command("g-1")).status == 200

    digest = :crypto.hash(:sha256, receipt <> "\n" <> ann.address)
    assert [command] = logged_commands()

    assert command["payload"]["auth"]["credential_ref"] ==
             "sha256:" <> Base.encode16(digest, case: :lower)
  end

  test "only the canonical workspace bodies reach the workspace", c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)

    for {op, body} <- [
          {"get", %{}},
          {"get", %{id: 1}},
          {"changes", %{after_seq: "1"}},
          {"create", %{as_key: 1, command_id: "c-1", type: "goal", data: @goal}},
          {"create",
           %{as_key: "1", command_id: "c-1", type: "goal", scope: "fleet", data: @goal}},
          {"patch", %{as_key: 1, command_id: "c-1", id: "goal#1", set: %{}}},
          {"patch",
           %{as_key: 1, command_id: "c-1", id: "goal#1", expected_version: 1, reason: nil}},
          {"link", %{as_key: 1, command_id: "c-1", source: "a", target: "b"}},
          {"unlink", %{as_key: 1, relation_id: "rel#1"}},
          {"archive", %{as_key: 1, command_id: "c-1", id: "goal#1"}},
          {"delete", %{id: "goal#1"}}
        ] do
      assert graph(c, ann, op, body).status == 401
    end

    for {op, body} <- [
          {"changes", %{limit: 501}},
          {"changes", %{after_seq: -1}},
          {"create", %{as_key: 0, command_id: "c-1", type: "goal", scope: "fleet", data: @goal}},
          {"archive", %{as_key: 1, command_id: "c-1", id: "goal#1", expected_version: 2 ** 70}}
        ] do
      refused = graph(c, ann, op, body)
      assert {refused.status, refused.body} == {422, %{"error" => "out_of_range"}}
    end
  end

  test "a sync records the agent's check-in and tells it its keys, their limits and the unfinished tasks they have taken",
       c do
    start_graph(c)
    [ann, bea] = pair_agents(c)

    doing =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        type: "task",
        data: %{
          title: "Draft the brief",
          progress: "doing",
          assignee_key: 1,
          next_step: "Pick a customer"
        }
      })

    for {agent, key, id, data} <- [
          {ann, 1, "t-2", %{title: "Finished", progress: "done", assignee_key: 1}},
          {ann, 1, "t-3", %{title: "Nobody's yet"}},
          {bea, 2, "t-4", %{title: "Bea's", progress: "doing", assignee_key: 2}},
          {ann, 1, "t-5",
           %{title: "Only a deliverable", assignee_key: 1, deliverable: "A one-page brief"}}
        ],
        do: write!(c, agent, "create", %{as_key: key, command_id: id, type: "task", data: data})

    synced = sync(c, ann, %{"general" => 0}, 0, %{kind: "scheduled", every_minutes: 60})

    assert synced.status == 200
    assert ContractSchema.errors(synced.body, "FleetSync") == []

    assert %{
             "status" => "confirming_schedule",
             "status_label" => "Waiting for a second scheduled check-in",
             "schedule_minutes" => 60,
             "schedule_confirmed" => false
           } = synced.body["check_in"]

    doing_id = doing["id"]

    assert %{
             "as_key" => 1,
             "keys" => [%{"token_id" => 1, "limits" => %{"written_at" => _} = limits}],
             "tasks" => [
               # A task with no next step says so, rather than naming its deliverable.
               %{"title" => "Only a deliverable", "next_step" => nil},
               %{
                 "id" => ^doing_id,
                 "title" => "Draft the brief",
                 "progress" => "doing",
                 "next_step" => "Pick a customer",
                 "version" => 1
               }
             ]
           } = synced.body["yours"]

    assert Map.delete(limits, "written_at") == %{
             "money" => Keys.default_limits().money,
             "your_information" => Keys.default_limits().information,
             "outside_keyfleet" => Keys.default_limits().outside,
             "check_with_owner_first" => Keys.default_limits().check_first
           }

    # Its writes in the workspace are its latest contribution here.
    {:ok, profile} = Agents.get_my_profile(actor: agent_actor(ann))
    assert %{last_contribution_kind: :workspace} = Agents.get_check_in!(profile.id, @fleet)

    # An agent running no key here has nothing of its own in the fleet.
    visitor = sync(c, join(c, "Cy"), %{"general" => 0}, 0)
    assert visitor.body["check_in"]["status"] == "connected_now"
    assert visitor.body["yours"] == %{"as_key" => nil, "keys" => [], "tasks" => []}
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

  defp log_id(fleet \\ @fleet) do
    {:ok, %{"result" => %{"run_id" => run_id}}} = Writer.request(fleet, "hello", %{})
    run_id
  end

  defp deploy(fleet, contract) do
    fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end

  # The Cascade fleet deployed and fresh, with these keys sold.
  defp sell_levelled(token_ids) do
    if Chain.get_cursor!(@levelled) == nil do
      ChainHelpers.seed_cursor!(@levelled)
      deploy(@levelled, "0x" <> String.duplicate("6", 40))
    end

    for token_id <- token_ids, do: record_owner(token_id, 1, owner_wallet(token_id), @levelled)
  end

  # One agent for each named Cascade key, paired by the key's owner.
  defp pair_levelled(c, names_and_keys) do
    for {name, token_id} <- names_and_keys do
      agent = join(c, name)
      pair(c, agent, token_id, owner_wallet(token_id), @levelled)
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
    assert {refused.status, refused.body["error"], refused.body["details"]} ==
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

  # Two agents, each running one of the fleet's two keys for its owner.
  defp pair_agents(c) do
    for {token_id, name} <- [{1, "Ann"}, {2, "Bea"}] do
      agent = join(c, name)
      pair(c, agent, token_id, @owners[token_id])
      agent
    end
  end

  defp pair(c, agent, token_id, owner_wallet, fleet \\ @fleet) do
    path = "/api/v1/agent/keys/#{fleet}/#{token_id}/pairing"
    assert send_signed(c, agent, "POST", path, %{}).status == 200

    owner = %Actors.Human{human_account_id: token_id, wallet_addresses: [owner_wallet]}
    [request] = Keys.list_pairing_requests!(fleet, token_id, actor: owner)
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
  end

  defp commands(c, agent, fleet \\ @fleet) do
    events = graph(c, agent, "changes", %{limit: 500}, fleet).body["events"]
    for %{"type" => "keyfleet.command"} = event <- events, do: event
  end

  # The command records as the log itself keeps them, authority stamp and all.
  defp logged_commands do
    {:ok, %{"result" => %{"events" => events}}} =
      Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    for %{"type" => "keyfleet.command"} = event <- events, do: event
  end

  defp join(c, name) do
    {:ok, signer} = Siwa.LocalSigner.new()
    body = %{name: name, declared_harness: "local"}
    assert send_signed(c, signer, "POST", "/api/v1/agent/join/status", body).status == 200
    signer
  end

  defp agent_actor(signer),
    do: %Actors.Agent{wallet_address: signer.address, chain_id: 8453, audience: "keyfleet"}

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

  defp sync(c, agent, rooms, graph_after_seq, run \\ %{kind: "session"}) do
    send_signed(c, agent, "POST", "/api/v1/agent/fleets/#{@fleet}/sync", %{
      rooms: Enum.map(rooms, fn {slug, seq} -> %{slug: slug, after_seq: seq} end),
      graph: %{after_seq: graph_after_seq},
      proposals: %{after_seq: 0},
      run: run
    })
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
            keyId: claims["key_id"],
            receiptExpiresAt:
              DateTime.from_unix!(claims["exp"], :millisecond) |> DateTime.to_iso8601(),
            requiredHeaders:
              Siwa.required_authenticated_request_headers(payload["body"], :wallet),
            requiredCoveredComponents:
              Siwa.required_authenticated_request_components(
                payload["headers"],
                payload["body"],
                :wallet
              ),
            coveredComponents: covered,
            principal: %{
              kind: "wallet",
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              audience: claims["aud"]
            }
          }
        })

      {:error, _reason} ->
        answer(conn, 401, %{error: %{code: "invalid_proof"}})
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
