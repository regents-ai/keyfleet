defmodule KeyFleetWeb.AgentGraphJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Graph.Writer
  alias KeyFleet.Keys
  alias KeyFleet.Rooms

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @contract "0x" <> String.duplicate("7", 40)
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
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(KeyFleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_core_rooms!()

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        deployed_block: 1
      },
      actor: %Actors.System{}
    )

    for {token_id, wallet} <- @owners, do: record_owner(token_id, 0, wallet)

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    Application.put_env(:keyfleet, :siwa_broker_url, server(:broker, &broker(&1, &2, secret)))
    app = server(:product, &KeyFleetWeb.Endpoint.call(&1, KeyFleetWeb.Endpoint.init(&2)))

    %{app: app, secret: secret, data_dir: Path.join(tmp_dir, "graph"), sandbox: owner}
  end

  test "two agents build a goal and a service with tasks, evidence and links, each edit credited to its key",
       c do
    start_graph(c)
    [ann, bea] = pair_agents(c)

    posted =
      send_signed(c, ann, "POST", "/api/v1/agent/fleets/#{@fleet}/rooms/work/messages/send", %{
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
          discussion: [%{room: "work", seq: 1}]
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

    read = graph(c, bea, "get", %{id: goal["id"]})
    assert read.status == 200
    assert read.body["object"]["data"]["title"] == "First paying customer"
    assert read.body["object"]["sys"]["created_by"]["key"]["token_id"] == 1
    assert read.body["object"]["sys"]["created_by"]["wallet"] == ann.address

    assert [%{"type" => "implements", "source" => source}] = read.body["relations"]
    assert source == task["id"]

    assert graph(c, ann, "get", %{id: note["id"]}).body["object"]["data"]["discussion"] ==
             [%{"room" => "work", "seq" => 1}]

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

    # Anyone signed in may read the workspace; its log names who did what.
    reader = join(c, "Reader")
    changes = graph(c, reader, "changes", %{after_seq: 0, limit: 500})
    assert changes.status == 200
    commands = for %{"type" => "keyfleet.command"} = event <- changes.body["events"], do: event

    assert length(commands) == 9
    [first | _] = commands
    [pairing] = Keys.my_pairings!(actor: agent_actor(ann))

    assert first["payload"]["principal"] ==
             "member:8453:#{@contract}:1@0/agent:#{ann.address}"

    assert %{
             "key" => %{"chain_id" => 8453, "contract" => @contract, "token_id" => 1},
             "ownership_epoch" => 0,
             "kind" => "agent",
             "operator_wallet" => operator,
             "pairing_id" => pairing_id,
             "credential_ref" => "sha256:" <> digest,
             "chain_block" => 1_000
           } = first["payload"]["auth"]

    assert {operator, pairing_id} == {ann.address, pairing.id}
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
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
    record_owner(1, 1, "0x" <> String.duplicate("c", 40))
    :sys.resume(writer)

    refused = Task.await(waiting, 15_000)
    assert refused.status == 403
    assert refused.body["error"] == "not_a_key_holder"

    object = graph(c, ann, "get", %{id: goal["id"]}).body["object"]
    assert object["version"] == 1
    assert object["data"]["status"] == "open"

    assert %{"key" => %{"token_id" => 1}, "ownership_epoch" => 0, "wallet" => wallet} =
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
          principal: "member:8453:#{@contract}:2@0/human:#{@owners[2]}",
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

    refused = graph(c, ann, "create", %{create | scope: "level:1"})
    assert {refused.status, refused.body["error"]} == {400, "bad_request"}

    events = graph(c, ann, "changes", %{}).body["events"]
    assert Enum.count(events, &(&1["type"] == "keyfleet.command")) == 1
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

  test "an unknown fleet is not found, and a fleet whose workspace is down says so", c do
    start_graph(c)
    [ann, _bea] = pair_agents(c)

    for {op, body} <- [
          {"get", %{id: "goal#1"}},
          {"create", %{as_key: 1, command_id: "u-1", type: "goal", scope: "fleet", data: @goal}}
        ] do
      missing = send_signed(c, ann, "POST", "/api/v1/agent/fleets/hull_survey/graph/#{op}", body)
      assert {missing.status, missing.body["error"]} == {404, "fleet_unknown"}
    end

    down =
      send_signed(c, ann, "POST", "/api/v1/agent/fleets/fibonacci_cascade/graph/get", %{
        id: "goal#1"
      })

    assert {down.status, down.body["error"]} == {503, "graph_unavailable"}

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
    Ecto.Adapters.SQL.Sandbox.mode(KeyFleet.Repo, :manual)
    :sys.resume(writer)
    refused = Task.await(waiting, 15_000)
    Ecto.Adapters.SQL.Sandbox.mode(KeyFleet.Repo, {:shared, c.sandbox})

    assert {refused.status, refused.body["error"]} == {503, "graph_unavailable"}
    assert refused.body["message"] =~ "nothing was written"
    assert commands(c, ann) == []
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
    record_owner(1, 1, new_owner)
    cal = join(c, "Cal")
    pair(c, cal, 1, new_owner)

    goal = write!(c, cal, "create", %{as_key: 1, command_id: "g-1", type: "goal", data: @goal})

    assert %{"ownership_epoch" => 1, "wallet" => wallet} =
             graph(c, cal, "get", %{id: goal["id"]}).body["object"]["sys"]["created_by"]

    assert wallet == cal.address
    assert [command] = commands(c, cal)
    assert command["payload"]["principal"] == "member:8453:#{@contract}:1@1/agent:#{cal.address}"
    assert command["payload"]["auth"]["ownership_epoch"] == 1
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
    assert [command] = commands(c, ann)

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

  defp start_graph(c, opts \\ []) do
    start_supervised!(
      {KeyFleet.Graph.Supervisor,
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
       )}
    )

    await(fn -> match?({:ok, _}, Writer.request(@fleet, "hello", %{})) end)
  end

  defp writer do
    [{pid, _timeout}] = Registry.lookup(KeyFleet.Graph.Registry, @fleet)
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

  defp pair(c, agent, token_id, owner_wallet) do
    path = "/api/v1/agent/keys/#{@fleet}/#{token_id}/pairing"
    assert send_signed(c, agent, "POST", path, %{}).status == 200

    owner = %Actors.Human{human_account_id: token_id, wallet_addresses: [owner_wallet]}
    [request] = Keys.list_pairing_requests!(@fleet, token_id, actor: owner)
    Keys.approve_pairing!(request, %{}, actor: owner)
  end

  defp commands(c, agent) do
    events = graph(c, agent, "changes", %{limit: 500}).body["events"]
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

  defp record_owner(token_id, epoch, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: wallet,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> Base.encode16(<<token_id, epoch, 0::240>>, case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp goal_command(command_id),
    do: %{as_key: 1, command_id: command_id, type: "goal", scope: "fleet", data: @goal}

  # Creates in the fleet scope and answers what was created.
  defp write!(c, agent, "create", body) do
    body = Map.merge(%{type: "service", scope: "fleet"}, body)
    written = graph(c, agent, "create", body)
    assert written.status == 200
    assert written.body["replayed"] == false
    written.body["result"]
  end

  defp graph(c, agent, op, body),
    do: send_signed(c, agent, "POST", "/api/v1/agent/fleets/#{@fleet}/graph/#{op}", body)

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
