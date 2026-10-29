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
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys
  alias Keyfleet.Rooms

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  # `general`'s repository is named after its fleet.
  @repository @fleet
  @contract "0x" <> String.duplicate("7", 40)
  @cascade "fibonacci_cascade"
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
    take_over_general(@fleet, @owners[1])

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    Application.put_env(:keyfleet, :siwa_broker_url, server(:broker, &broker(&1, &2, secret)))
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))

    %{app: app, secret: secret, data_dir: Path.join(tmp_dir, "graph"), sandbox: owner}
  end

  test "two agents of one key patching one version at once get one success and one conflict",
       c do
    start_graph(c)
    [ann, bea] = for name <- ["Ann", "Bea"], do: tap(join(c, name), &shard(&1, 1))

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

    answers =
      [{ann, "achieved"}, {bea, "dropped"}]
      |> Enum.map(fn {agent, status} ->
        Task.async(fn ->
          {status,
           graph(c, agent, "patch", %{
             as_key: 1,
             command_id: "race-#{status}",
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

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

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

  test "a request cannot name its own author or standing, or write server-owned fields",
       c do
    start_graph(c)
    [ann, _bea] = shard_agents(c)

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

    create = %{as_key: 1, command_id: "f-1", project: "general", type: "goal", data: @goal}

    for {field, value} <- [
          actor: "system",
          principal: "member:8453:#{@contract}:2@1/human:#{@owners[2]}",
          auth: %{kind: "human"},
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

    assert {refused.status, refused.body["error"]["details"]["fields"]} == {422, ["sys"]}

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

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

    joined = graph(c, bea, "join", %{as_key: 2, command_id: "j-1", id: goal["id"]})
    assert joined.status == 200

    read = graph(c, bea, "get", %{id: goal["id"]}).body
    assert read["agents"] == %{ann.address => "Ann", bea.address => "Bea"}
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []

    changes = graph(c, ann, "changes", %{}).body
    assert changes["agents"] == %{ann.address => "Ann", bea.address => "Bea"}
    assert ContractSchema.errors(changes, "WorkspaceChanges") == []

    actors = Map.new(changes["events"], &{&1["type"], &1["actor"]})
    assert String.ends_with?(actors["object.created"], "/agent:" <> ann.address)
    assert String.ends_with?(actors["patch.applied"], "/agent:" <> bea.address)
  end

  test "the board lists the newest goals as the Project place does, and what members pinned, to members only",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

    assert graph(c, bea, "join", %{as_key: 2, command_id: "j-1", id: goal["id"]}).status == 200

    holder = %Actors.Human{human_account_id: 1, wallet_addresses: [@owners[1]]}

    pin = %{
      fleet_id: @fleet,
      project: "general",
      place: :code,
      target: "goals",
      title: "goals",
      folder?: true
    }

    Graph.pin!(pin, actor: holder)

    Graph.pin!(
      %{pin | place: :docs, target: "nb-0123456789abcdef", title: "Plan", folder?: false},
      actor: holder
    )

    board = graph(c, bea, "board", %{}).body
    assert ContractSchema.errors(board, "WorkspaceBoard") == []

    # The goal just made is open and joined; a starting goal nobody joined
    # isn't counted, and there are no tasks yet.
    assert board["counts"] == %{
             "open_goals" => 1,
             "open_tasks" => 0,
             "working" => 0,
             "waiting_review" => 0,
             "accepted" => 0
           }

    # The graph drawn around the goal holds the goal alone, as nothing is
    # linked to it yet; an id that names no goal has no map.
    around = graph(c, bea, "view", %{goal: goal["id"]}).body
    assert ContractSchema.errors(around, "WorkspaceGraph") == []
    assert Enum.map(around["nodes"], & &1["id"]) == [goal["id"]]
    assert graph(c, bea, "view", %{goal: "goal#999999"}).body["nodes"] == []

    # The newest first: the goal just made, then the starting goals.
    assert [newest | starting] = board["goals"]
    assert %{"title" => "First paying customer", "status" => "open", "joined" => 1} = newest
    assert newest["id"] == goal["id"]

    assert String.ends_with?(
             newest["url"],
             KeyfleetWeb.WorkspacePage.item_path(@fleet, goal["id"])
           )

    assert starting != [] and Enum.all?(starting, & &1["starting"])
    assert board["more_goals"] == false
    assert [%{"path" => "goals", "folder" => true, "url" => code_url}] = board["pinned_code"]
    assert String.ends_with?(code_url, Keyfleet.Code.files_path(@fleet, @repository, "goals"))

    assert [%{"notebook_id" => "nb-0123456789abcdef", "title" => "Plan"}] =
             board["pinned_notebooks"]

    stranger = join(c, "Stranger")
    refused = graph(c, stranger, "board", %{})
    assert {refused.status, refused.body["error"]["code"]} == {403, "workspace_members_only"}
    assert graph(c, bea, "board", %{}, "no_such_fleet").status == 404
  end

  test "a board the database can't read answers that the workspace is unavailable", c do
    start_graph(c)
    [_ann, bea] = shard_agents(c)

    # Renamed inside the test's own transaction, so the pins read fails the
    # way a database that refuses it does; the rename ends with the test.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.workspace_pins RENAME TO workspace_pins_away"
    )

    capture_log(fn ->
      refused = graph(c, bea, "board", %{})
      assert {refused.status, refused.body["error"]["code"]} == {503, "graph_unavailable"}

      for pid <- Task.Supervisor.children(Keyfleet.ErrorSaves) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end
    end)
  end

  test "an agent joins a goal to follow it: the goal names who joined, and the agent's sync lists it",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)

    goal =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

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
        project: "general",
        type: "task",
        data: %{title: "Draft"}
      })

    assert graph(c, ann, "join", %{as_key: 1, command_id: "j-3", id: task["id"]}).status == 422

    left = graph(c, bea, "leave", %{as_key: 2, command_id: "l-1", id: goal["id"]})
    assert left.body["result"] == %{"id" => goal["id"], "version" => 3}
    assert sync(c, bea)["yours"]["goals"] == []
  end

  # Costly failure: work its own Key or wallet accepted, or a submission read
  # as accepted, would let one member approve what the fleet may later pay for.
  test "an agent submits a task with its evidence, and only another Key and wallet may review it",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)

    task =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        project: "general",
        type: "task",
        data: %{title: "Draft"}
      })

    source = %{title: "The brief", source_uri: "https://example.com/brief"}

    evidence =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "e-1",
        project: "general",
        type: "evidence",
        data: source
      })

    submitted =
      graph(c, ann, "submit", %{
        as_key: 1,
        command_id: "s-1",
        id: task["id"],
        expected_version: 1,
        result_ref: "https://example.com/brief",
        evidence: [evidence["id"]]
      })

    assert submitted.body["result"] == %{"id" => task["id"], "version" => 2}
    assert last_did(ann, @fleet) == :submit

    read = graph(c, bea, "get", %{id: task["id"]}).body
    assert %{"review" => "awaiting_review", "data" => %{"progress" => "done"}} = read["object"]
    assert %{"version" => 2, "evidence" => [evidence_id]} = read["object"]["sys"]["submitted"]
    assert evidence_id == evidence["id"]
    assert [%{"type" => "produces", "target" => ^evidence_id}] = read["relations"]
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []

    review = %{
      as_key: 1,
      command_id: "r-1",
      task: task["id"],
      task_version: 2,
      decision: "accept",
      rationale: "The brief answers the deliverable.",
      conflicts_of_interest: "none"
    }

    refused = graph(c, ann, "review", review)
    assert {refused.status, refused.body["error"]["code"]} == {403, "self_review"}

    # The longest reasons a review gives fit in one write.
    disputed =
      graph(c, bea, "review", %{
        review
        | as_key: 2,
          command_id: "r-2",
          decision: "dispute",
          rationale: String.duplicate("a", 4_000),
          conflicts_of_interest: String.duplicate("b", 1_000)
      })

    assert disputed.status == 200
    assert last_did(bea, @fleet) == :review
    assert graph(c, ann, "get", %{id: task["id"]}).body["object"]["review"] == "disputed"

    receipt = graph(c, ann, "get", %{id: disputed.body["result"]["id"]}).body

    assert %{"task" => task_id, "task_version" => 2, "evidence" => [%{"version" => 1}]} =
             receipt["object"]["sys"]["review"]

    assert task_id == task["id"]
    assert receipt["object"]["sys"]["review"]["submitted_by"]["wallet"] == ann.address
    assert ContractSchema.errors(receipt, "WorkspaceObjectView") == []
  end

  # Costly failure: a reviewer that never hears it was asked, or a review
  # that says the work reproduced from a commit other than the one it judged,
  # leaves the pilot's patches unchecked while they read as checked.
  test "a task names its reviewer, commit and notebook; the reviewer's sync lists it until it says whether the work reproduced",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)
    commit = KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, String.duplicate("a", 40))

    notebook =
      Keyfleet.Notebooks.url(
        @fleet,
        "/projects/proj-0123456789abcdef/notebooks/nb-0123456789abcdef"
      )

    task =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        project: "general",
        type: "task",
        data: %{
          title: "Fewer notices",
          acceptance_criteria: ["Each agent gets at most one notice a minute"],
          reviewer_key: 2,
          commit_ref: commit,
          notebook_ref: notebook
        }
      })

    assert sync(c, bea)["yours"]["reviews"] == []

    submit = %{
      as_key: 1,
      command_id: "s-1",
      id: task["id"],
      expected_version: 1,
      result_ref: commit
    }

    assert graph(c, ann, "submit", submit).status == 200

    synced = sync(c, bea)

    assert [%{"id" => id, "title" => "Fewer notices", "version" => 2}] =
             synced["yours"]["reviews"]

    assert id == task["id"]
    assert ContractSchema.errors(synced, "FleetSync") == []
    assert sync(c, ann)["yours"]["reviews"] == []

    review = %{
      as_key: 2,
      command_id: "r-1",
      task: task["id"],
      task_version: 2,
      decision: "accept",
      rationale: "Ran the tests and the notebook from the commit.",
      conflicts_of_interest: "none",
      reproduction: "failed"
    }

    refused = graph(c, bea, "review", review)
    assert {refused.status, refused.body["error"]["code"]} == {422, "invalid"}

    reviewed = graph(c, bea, "review", %{review | command_id: "r-2", reproduction: "passed"})
    assert reviewed.status == 200
    assert sync(c, bea)["yours"]["reviews"] == []

    receipt = graph(c, ann, "get", %{id: reviewed.body["result"]["id"]}).body
    assert receipt["object"]["data"]["reproduction"] == "passed"
    assert receipt["object"]["sys"]["review"]["commit_ref"] == commit
    assert ContractSchema.errors(receipt, "WorkspaceObjectView") == []

    read = graph(c, ann, "get", %{id: task["id"]}).body["object"]
    assert read["review"] == "reproduced"

    assert read["data"]["acceptance_criteria"] == [
             "Each agent gets at most one notice a minute"
           ]

    patched =
      graph(c, ann, "patch", %{
        as_key: 1,
        command_id: "p-1",
        id: task["id"],
        expected_version: 2,
        set: %{
          commit_ref:
            KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, String.duplicate("b", 40))
        }
      })

    assert patched.status == 200
    assert [%{"version" => 3}] = sync(c, bea)["yours"]["reviews"]
  end

  test "every workspace opens with its starting goals, which agents join and link work to but never change or archive",
       c do
    start_graph(c)
    [ann, bea] = shard_agents(c)

    starting =
      for %{"type" => "object.created", "payload" => %{"object" => object}} <-
            graph(c, ann, "changes", %{}).body["events"],
          do: object

    assert Enum.map(starting, &{&1["data"]["title"], &1["data"]["sys"]["starting"]}) ==
             Keyfleet.GoalIdeas.starting_goals()
             |> Enum.with_index(1)
             |> Enum.map(fn {goal, number} -> {goal.title, number} end)
             |> Enum.reverse()

    assert Enum.all?(starting, &(&1["data"]["sys"]["created_by"] == nil))
    assert Graph.open_goals!(@fleet) == []

    goal = List.last(starting)
    assert goal["data"]["sys"]["starting"] == 1
    assert goal["data"]["title"] == "Plan a service that earns stablecoins"
    joined = graph(c, bea, "join", %{as_key: 2, command_id: "j-1", id: goal["id"]})
    assert joined.body["result"] == %{"id" => goal["id"], "version" => 2}

    task =
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "t-1",
        project: "general",
        type: "task",
        data: %{title: "Draft"}
      })

    linked =
      graph(c, ann, "link", %{
        as_key: 1,
        command_id: "k-1",
        source: task["id"],
        target: goal["id"],
        type: "implements"
      })

    assert linked.status == 200

    patched =
      graph(c, ann, "patch", %{
        as_key: 1,
        command_id: "p-1",
        id: goal["id"],
        expected_version: 2,
        set: %{status: "dropped"}
      })

    archived =
      graph(c, ann, "archive", %{
        as_key: 1,
        command_id: "a-1",
        id: goal["id"],
        expected_version: 2
      })

    for refused <- [patched, archived] do
      assert {refused.status, refused.body["error"]["code"]} == {422, "invalid"}
    end

    read = graph(c, ann, "get", %{id: goal["id"]}).body
    assert read["object"]["version"] == 2
    assert ContractSchema.errors(read, "WorkspaceObjectView") == []
    assert [%{title: "Plan a service that earns stablecoins"}] = Graph.open_goals!(@fleet)
  end

  # Levels decide nothing about the workspace: every Key of a Fibonacci fleet
  # adds to all of it, as in every other fleet. Syndicate keys other suites
  # commit outside the sandbox would count as sold, so this runs on Cascade.
  test "every key adds to the whole fleet, and a task another key holds is forked rather than taken, changed or archived",
       c do
    sell_cascade(1..3)
    start_graph(c, fleets: [@fleet, @cascade])
    [ann, cal] = shard_cascade(c, [{"Ann", 1}, {"Cal", 3}])

    draft = %{
      as_key: 1,
      command_id: "t-1",
      project: "general",
      type: "task",
      data: %{title: "Draft the brief"}
    }

    task = write!(c, ann, "create", draft, @cascade)

    assign = fn agent, key, version, assignee ->
      body = %{
        as_key: key,
        command_id: "a-#{key}-#{version}-#{inspect(assignee)}",
        id: task["id"],
        expected_version: version,
        set: %{assignee_key: assignee}
      }

      graph(c, agent, "patch", body, @cascade)
    end

    assert last_did(ann, @cascade) == :workspace
    assert assign.(ann, 1, 1, 1).status == 200
    assert last_did(ann, @cascade) == :task

    for assignee <- [3, nil] do
      refused = assign.(cal, 3, 2, assignee)

      assert {refused.status, refused.body["error"]["code"],
              refused.body["error"]["details"]["assignee_key"]} == {422, "forbidden_field", 1}

      assert ContractSchema.errors(refused.body, "WorkspaceError") == []
    end

    edit = %{as_key: 3, command_id: "e-1", id: task["id"], expected_version: 2}
    archive = %{as_key: 3, command_id: "x-1", id: task["id"], expected_version: 2}

    for refused <- [
          graph(c, cal, "patch", Map.put(edit, :set, %{progress: "blocked"}), @cascade),
          graph(c, cal, "archive", archive, @cascade)
        ] do
      assert {refused.status, refused.body["error"]["code"],
              refused.body["error"]["details"]["owner_key"]} == {403, "not_owner", 1}

      assert refused.body["error"]["hint"] =~ "Fork"
      assert ContractSchema.errors(refused.body, "WorkspaceError") == []
    end

    forked = graph(c, cal, "fork", %{as_key: 3, command_id: "f-1", id: task["id"]}, @cascade)
    assert forked.status == 200
    assert last_did(cal, @cascade) == :task
    assert ContractSchema.errors(forked.body, "WorkspaceWrite") == []

    fork = graph(c, cal, "get", %{id: forked.body["result"]["id"]}, @cascade).body

    assert {fork["object"]["data"]["assignee_key"], fork["object"]["data"]["progress"]} ==
             {3, "doing"}

    assert Enum.map(fork["relations"], &{&1["type"], &1["target"]}) == [{"forks", task["id"]}]
    assert ContractSchema.errors(fork, "WorkspaceObjectView") == []

    # The holder gives the task away, the Key it went to drops it, and the
    # Key that created it archives it.
    assert assign.(ann, 1, 2, 3).status == 200
    assert last_did(ann, @cascade) == :workspace
    assert assign.(cal, 3, 3, nil).status == 200

    archived =
      graph(
        c,
        ann,
        "archive",
        %{archive | as_key: 1, command_id: "x-2", expected_version: 4},
        @cascade
      )

    assert archived.status == 200
    assert graph(c, ann, "get", %{id: task["id"]}, @cascade).body["object"]["sys"]["archived"]
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
          project: "general",
          type: "goal",
          data: @goal
        })

      assert {refused.status, refused.body["error"]["code"]} == {403, "not_a_key_holder"}
    end

    assert logged_commands() == []

    # Nor may it read the workspace, its graph included: that needs a Key or a
    # shard of one.
    for {op, input} <- [{"changes", %{}}, {"get", %{id: "goal#1"}}, {"view", %{}}] do
      read = graph(c, stranger, op, input)
      assert {read.status, read.body["error"]["code"]} == {403, "workspace_members_only"}
      assert ContractSchema.errors(read.body, "WorkspaceError") == []
    end
  end

  test "a write whose outcome never came back says so, and its retry applies it once", c do
    start_graph(c, reply_timeout: 1_000)
    [ann, _bea] = shard_agents(c)
    create = %{as_key: 1, command_id: "g-1", project: "general", type: "goal", data: @goal}

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
    assert %{"id" => "goal#" <> _, "version" => 1} = retried.body["result"]
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

    goal =
      write!(c, cal, "create", %{
        as_key: 1,
        command_id: "g-1",
        project: "general",
        type: "goal",
        data: @goal
      })

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
      write!(c, ann, "create", %{
        as_key: 1,
        command_id: "n-1",
        project: "general",
        type: "note",
        data: note
      })

    assert graph(c, ann, "get", %{id: written["id"]}).body["object"]["data"]["body"] ==
             note.body

    too_large = %{note | body: String.duplicate("word ", 10_010)}

    refused =
      graph(c, ann, "create", %{
        as_key: 1,
        command_id: "n-2",
        project: "general",
        type: "note",
        data: too_large
      })

    assert {refused.status, refused.body["error"]["code"]} == {413, "request_too_large"}
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
  defp sell_cascade(token_ids) do
    if Chain.get_cursor!(@cascade) == nil do
      ChainHelpers.seed_cursor!(@cascade)
      ChainHelpers.deploy!(@cascade)
    end

    for token_id <- token_ids, do: record_owner(token_id, 1, owner_wallet(token_id), @cascade)
    take_over_general(@cascade, owner_wallet(1))
  end

  # Key 1 takes over the fleet's archived `general`, so new work can go there.
  defp take_over_general(fleet, wallet) do
    holder = %Actors.Human{human_account_id: 1, wallet_addresses: [wallet]}
    Keyfleet.Projects.take_over_project!(fleet, 1, "general", actor: holder)
  end

  # One agent for each named Cascade key, holding a shard its owner issued.
  defp shard_cascade(c, names_and_keys) do
    for {name, token_id} <- names_and_keys do
      agent = join(c, name)
      shard(agent, token_id, @cascade)
      agent
    end
  end

  defp owner_wallet(token_id),
    do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  defp writer do
    [pid] = :pg.get_members(Keyfleet.Graph.Processes, {Keyfleet.Graph.Writer, @fleet})
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

  # What the agent did last in the fleet, as its check-in records it.
  defp last_did(signer, fleet) do
    [profile] = Keyfleet.Agents.agents_by_wallets!([signer.address], load: [:check_ins])
    [check_in] = Enum.filter(profile.check_ins, &(&1.fleet_id == fleet))
    check_in.last_contribution_kind
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
    do: %{as_key: 1, command_id: command_id, project: "general", type: "goal", data: @goal}

  # Creates a service unless the body names another type, and answers what
  # was created.
  defp write!(c, agent, "create", body, fleet \\ @fleet) do
    body = Map.merge(%{project: "general", type: "service"}, body)
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

    case Siwa.verify_authenticated_request(KeyfleetWeb.SignedAgentHelpers.siwa_request(payload),
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
