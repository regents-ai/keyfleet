defmodule KeyfleetWeb.McpConnectorTest do
  # The Claude connector's address, /mcp, through this site's own endpoint,
  # router, sign-in, pairings and tools, with the connector switched on:
  # - what a token is listed follows its permissions alone, the same before and
  #   after its identity pairs; who a request runs as follows its identity's
  #   pairing too: the fleet tools run only for the agent paired with that same
  #   account, and a wallet's tools never;
  # - each app a person connects keeps its own identity, kept across a refreshed
  #   token: a second app of an account paired through the first stays the app;
  # - the account's budget is spent before the sign-in server is asked, so a
  #   request past it never reaches the server, even while that server is down;
  # - a pairing that ends or changes hands while a tool runs replaces the answer;
  # - each agent tool answers and refuses exactly as its signed request does,
  #   since both run the same code.
  # The hosted signer and the sign-in server are stand-ins; the rest is the site's.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.FeedHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias Keyfleet.SeasonHelpers
  alias Keyfleet.Seasons
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @coming_soon "fleet_tech_accelerant"
  @owner "0x" <> String.duplicate("a", 40)
  @site_key String.duplicate("k", 32)
  @identity_scope "regent.identity.manage"
  @agent_scopes "regent.identity.manage keyfleet.agent"
  @wallets __MODULE__.HostedWallets

  setup do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    # An app connected with the local signer's wallet keeps it as its hosted
    # identity's, so the same agent can also sign its own requests to the site.
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    app = SignedAgentHelpers.serve!(:product, &@endpoint.call(&1, @endpoint.init(&2)))
    connector_on()

    %{
      signer: signer,
      secret: secret,
      app: app,
      from: {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}
    }
  end

  describe "admission" do
    test "an identity-only token stays the app, paired or not: identity tools only", c do
      subject = account!()
      pair!(subject, c.signer.address)
      token = connect!(subject, @identity_scope, c.signer.address)

      assert Enum.sort(tool_names(token, c)) == Enum.sort(RegentMCPAgents.Tools.names())
      assert %{"error" => _} = call(token, "polls_list", %{fleet_id: @fleet}, c)
    end

    test "the agent permission with the identity paired to this account lists every fleet tool, the workspace's writes included, and no wallet tool",
         c do
      subject = account!()
      pair!(subject, c.signer.address)
      token = connect!(subject, @agent_scopes, c.signer.address)
      listed = tool_names(token, c)

      assert "workspace_create" in fleet_tools()
      assert Enum.sort(listed) == Enum.sort(RegentMCPAgents.Tools.names() ++ fleet_tools())

      for wallet_tool <- ["keys_claim", "proposals_vote"] do
        refute wallet_tool in listed
        assert %{"error" => _} = call(token, wallet_tool, %{fleet_id: @fleet}, c)
      end
    end

    test "the agent permission with the identity paired to another account, or to no one, stays the app: listed the agent's tools, running none of them",
         c do
      subject = account!()
      token = connect!(subject, @agent_scopes, c.signer.address)
      agent_tools = Enum.sort(RegentMCPAgents.Tools.names() ++ fleet_tools())

      assert Enum.sort(tool_names(token, c)) == agent_tools
      assert not_paired?(call(token, "polls_list", %{fleet_id: @fleet}, c))

      pair!(account!(), c.signer.address)
      assert Enum.sort(tool_names(token, c)) == agent_tools
      assert not_paired?(call(token, "polls_list", %{fleet_id: @fleet}, c))
    end

    # Claude reads the tool list once, when it connects, and keeps it: the list
    # it got before pairing must be the one that works after.
    test "with the agent permission the app is listed the same tools before and after it pairs, and runs a fleet tool only once paired",
         c do
      subject = account!()
      token = connect!(subject, @agent_scopes, c.signer.address)
      unpaired = json(mcp(rpc("tools/list"), token, c))["result"]["tools"]

      # A call for every fleet tool is more than a minute's budget.
      budget = Application.fetch_env!(:keyfleet, :mcp_rate_limit)
      put_env(:keyfleet, :mcp_rate_limit, Keyword.put(budget, :limit, 1_000))

      for tool <- fleet_tools() do
        assert not_paired?(call(token, tool, %{}, c)), tool
      end

      sync = %{"fleet_id" => @fleet, "rooms" => [%{"slug" => "general", "after_seq" => 0}]}
      assert not_paired?(call(token, "fleets_sync", sync, c))
      assert not_paired?(call(token, "fleets_show", %{fleet_id: @fleet}, c))
      refute Keyfleet.Repo.exists?(Keyfleet.Agents.CheckIn)

      pair!(subject, c.signer.address)
      assert json(mcp(rpc("tools/list"), token, c))["result"]["tools"] == unpaired

      assert %{"isError" => false, "structuredContent" => %{"id" => @fleet}} =
               result(call(token, "fleets_show", %{fleet_id: @fleet}, c))
    end

    test "a second app of an account already paired through another app runs its identity tools only",
         c do
      subject = account!()
      first = connect!(subject, @agent_scopes, c.signer.address)
      pair!(subject, c.signer.address)
      assert "polls_list" in tool_names(first, c)

      # Same account, same name, the agent permission: listed the same tools,
      # still not the paired agent.
      second = connect!(subject, @agent_scopes)
      assert Enum.sort(tool_names(second, c)) == Enum.sort(tool_names(first, c))
      assert not_paired?(call(second, "polls_list", %{fleet_id: @fleet}, c))
      assert [%{wallet: wallet}] = RegentAgents.list_my_agents!(actor: person(subject))
      assert String.downcase(wallet) == String.downcase(c.signer.address)
      assert "polls_list" in tool_names(first, c)
    end

    test "a refreshed token keeps its app's identity and its agent's tools", c do
      subject = account!()
      app = connect_app!(subject, @agent_scopes, c.signer.address)
      pair!(subject, c.signer.address)

      refreshed = refresh!(app)
      refute refreshed == app.access

      assert Enum.sort(tool_names(refreshed, c)) ==
               Enum.sort(RegentMCPAgents.Tools.names() ++ fleet_tools())
    end

    # Costly failure: an app that names the scheme in another case, which HTTP
    # allows (RFC 9110 §11.1), is asked to connect as if it sent no token, and
    # spends the budget of callers without one.
    test "the token's scheme is read in any case", c do
      token = connect!(account!(), @identity_scope)

      for scheme <- ["bearer", "BEARER", "bEaReR"] do
        answer =
          conn(:post, "/mcp", Jason.encode!(rpc("tools/list")))
          |> Map.put(:remote_ip, c.from)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", scheme <> " " <> token)
          |> @endpoint.call([])

        assert %{"result" => %{"tools" => tools}} = json(answer), scheme

        assert Enum.sort(Enum.map(tools, & &1["name"])) ==
                 Enum.sort(RegentMCPAgents.Tools.names())

        assert [policies] = get_resp_header(answer, "ratelimit-policy")
        assert policies =~ ~s("connector"), scheme
      end
    end

    # Both callers meet the same refusal: an app that hasn't connected, and an
    # agent that sent its call without its signature. Its hint sends the agent
    # to the served guide, which says how to sign.
    test "a request with no token of this site's, and no signature, is asked to connect or sign",
         c do
      for token <- [nil, "not-one-of-ours"] do
        refused = mcp(rpc("tools/list"), token, c)
        assert refused.status == 401
        assert error(refused)["code"] == "connection_required"
        assert [_challenge] = get_resp_header(refused, "www-authenticate")
        assert error(refused)["hint"] =~ KeyfleetWeb.PublicDocuments.url("/skill.md")
      end
    end

    test "a request with SIWA headers but no signature is asked to connect or sign, as an unsigned one is",
         c do
      body = Jason.encode!(rpc("tools/list"))

      for unsigned <- [
            [{"content-digest", Siwa.content_digest_for_body(body)}],
            [{"x-key-id", c.signer.address}, {"x-timestamp", "1"}]
          ] do
        refused =
          conn(:post, "/mcp", body)
          |> Map.put(:remote_ip, c.from)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> Map.update!(:req_headers, &(&1 ++ unsigned))
          |> @endpoint.call([])

        assert refused.status == 401
        assert error(refused)["code"] == "connection_required"
        assert [_challenge] = get_resp_header(refused, "www-authenticate")
      end

      refute_received {:broker_payload, _payload}
    end
  end

  # The same address for an agent that signs its own requests with its SIWA
  # key and sends no token: it is that agent, admitted as its signed requests
  # are, with the paired agent's tools and none of the identity tools.
  describe "an agent that signs its own requests" do
    test "paired, it lists every fleet tool and no identity or wallet tool, and each answers as its signed request does",
         c do
      pair!(account!(), c.signer.address)
      listed = Enum.map(signed_mcp(c, rpc("tools/list")).body["result"]["tools"], & &1["name"])
      assert Enum.sort(listed) == Enum.sort(fleet_tools())

      for tool <- RegentMCPAgents.Tools.names() ++ ["keys_claim", "proposals_vote"] do
        refute tool in listed
        assert %{"error" => _} = signed_call(c, tool, %{})
      end

      manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

      for {name, input} <- [
            {"polls_list", %{"fleet_id" => @fleet}},
            {"polls_list", %{"fleet_id" => "no_such_fleet"}},
            {"agents_profile", %{}}
          ] do
        http = http_twin(c, manifest[name], input)
        over_mcp = result(signed_call(c, name, input))

        if http.status in 200..299 do
          assert %{"isError" => false, "structuredContent" => answer} = over_mcp, name
          assert comparable(answer) == comparable(http.body), name
        else
          assert %{"isError" => true, "content" => [%{"text" => text}]} = over_mcp, name
          assert Jason.decode!(text)["error"] == http.body["error"], name
        end
      end
    end

    # A tool lists its browser tool's input, so a call that sends only what it
    # lists as required, leaving out what it lists as optional, is answered as
    # its signed request is.
    test "each fleet tool lists its browser tool's input, and a sync sending only what it requires is answered",
         c do
      pair!(account!(), c.signer.address)
      ChainHelpers.issue_shard!(@fleet, 1, c.signer.address)
      manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})
      listed = signed_mcp(c, rpc("tools/list")).body["result"]["tools"]

      for %{"name" => name, "inputSchema" => %{"properties" => %{"input" => input}}} <- listed do
        schema = manifest[name]["input_schema"]
        names = Map.keys(input["properties"])
        assert input["properties"] == Map.take(schema["properties"], names), name
        assert input["required"] == Enum.filter(schema["required"], &(&1 in names)), name
      end

      sync = Enum.find(listed, &(&1["name"] == "fleets_sync"))["inputSchema"]["properties"]
      assert sync["input"] == manifest["fleets_sync"]["input_schema"]

      input = %{
        "fleet_id" => @fleet,
        "rooms" => [],
        "graph" => %{"after_seq" => 0},
        "proposals" => %{"after_seq" => 0},
        "run" => %{"kind" => "session"}
      }

      assert Enum.sort(Map.keys(input)) == Enum.sort(sync["input"]["required"])

      for part <- ["graph", "proposals", "run"],
          do: assert(Map.keys(input[part]) == sync["input"]["properties"][part]["required"])

      http = http_twin(c, manifest["fleets_sync"], input)
      assert http.status == 200
      assert %{"isError" => false} = result(signed_call(c, "fleets_sync", input))
    end

    # messages_leave and its signed request (KeyfleetWeb.LeftMessagesApiTest)
    # leave one message: the request with the tool's operation_id answers the
    # tool's receipt, and both refuse the same input with the same words.
    test "messages_leave leaves a message, and answers and refuses as its signed request does",
         c do
      pair!(account!(), c.signer.address)

      {:ok, agent} =
        Keyfleet.Agents.with_pairing(%Actors.Agent{
          wallet_address: String.downcase(c.signer.address),
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        })

      Keyfleet.Agents.ensure_profile!(%{name: "Scout", declared_harness: "test"}, actor: agent)
      manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

      input = %{
        "topic" => "agents",
        "body" => "Hello team",
        "operation_id" => Ecto.UUID.generate()
      }

      assert %{"isError" => false, "structuredContent" => left} =
               result(signed_call(c, "messages_leave", input))

      again = http_twin(c, manifest["messages_leave"], input)
      assert {again.status, again.body} == {200, left}

      too_long = %{
        input
        | "body" => String.duplicate("a", 2001),
          "operation_id" => Ecto.UUID.generate()
      }

      http = http_twin(c, manifest["messages_leave"], too_long)
      assert http.status == 422

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               result(signed_call(c, "messages_leave", too_long))

      assert Jason.decode!(text)["error"] == http.body["error"]

      assert %{"code" => "invalid_message", "details" => [%{"field" => "body"}]} =
               http.body["error"]
    end

    test "unpaired, it is refused as its signed requests are", c do
      refused = signed_mcp(c, rpc("tools/list"))
      twin = signed(c, "GET", "/api/v1/agent/profile", nil)

      assert refused.status == 403
      assert refused.body["error"]["code"] == "agent_not_paired"
      assert {twin.status, twin.body} == {refused.status, refused.body}
    end

    test "a body changed after it was signed is refused", c do
      request =
        SignedAgentHelpers.sign(
          c.signer,
          c.secret,
          Siwa.Contract.authority(c.app),
          "POST",
          "/mcp",
          Jason.encode!(rpc("ping"))
        )

      pair!(account!(), c.signer.address)

      refused =
        Req.post!(c.app <> "/mcp",
          headers: Map.drop(request.headers, ["cookie", "authorization"]),
          body: Jason.encode!(rpc("tools/list")),
          retry: false
        )

      assert refused.status == 401
      assert refused.body["error"]["code"] == "http_signature_invalid"
    end

    # Costly failure: a call runs on a body other than the one its signature
    # declares.
    test "a call carries the body its content-digest declares, none declaring the empty body",
         c do
      pair!(account!(), c.signer.address)
      SignedAgentHelpers.start_real_broker!(self(), c.secret)

      cases =
        SignedAgentHelpers.body_cases(
          c.signer,
          c.secret,
          Siwa.Contract.authority(c.app),
          "POST",
          "/mcp",
          Jason.encode!(rpc("tools/list")),
          Jason.encode!(rpc("ping"))
        )

      answers =
        for {_name, request} <- cases do
          answer =
            Req.post!(c.app <> "/mcp",
              headers: Map.drop(request.headers, ["cookie", "authorization"]),
              body: request.body,
              retry: false
            )

          {answer.status, outcome(answer.body)}
        end

      unbound = {401, "http_body_binding_invalid"}

      # An empty call is signed in, then refused as no JSON-RPC call.
      assert answers == [
               {400, "bad_request"},
               {400, "bad_request"},
               {401, "http_headers_missing"},
               {200, :tools},
               unbound,
               unbound
             ]

      SignedAgentHelpers.assert_reported_bytes!(cases)
    end

    # Costly failure: a content-digest the site can't read, or a signature
    # header sent twice, crashes the connector or runs the call.
    test "a content-digest that isn't one sha-256 digest, or a header sent twice, is refused",
         c do
      SignedAgentHelpers.start_real_broker!(self(), c.secret)
      authority = Siwa.Contract.authority(c.app)
      body = Jason.encode!(rpc("tools/list"))
      digest = Siwa.Contract.body_component()

      unreadable =
        SignedAgentHelpers.sign_digest(
          c.signer,
          c.secret,
          authority,
          "POST",
          "/mcp",
          "not-a-digest"
        )

      signed = SignedAgentHelpers.sign(c.signer, c.secret, authority, "POST", "/mcp", body)

      answers =
        for headers <- [
              Map.to_list(unreadable.headers),
              [{digest, signed.headers[digest]} | Map.to_list(signed.headers)]
            ] do
          answer =
            Req.post!(c.app <> "/mcp",
              headers:
                Enum.reject(headers, fn {name, _value} -> name in ~w(cookie authorization) end),
              body: body,
              retry: false
            )

          {answer.status, outcome(answer.body)}
        end

      assert answers == [{401, "http_body_binding_invalid"}, {401, "duplicate_proof"}]
    end

    test "an answer whose pairing ends while the tool runs is replaced", c do
      subject = account!()
      agent = pair!(subject, c.signer.address)

      during_polls_list(fn ->
        :ok = RegentAgents.unpair_agent!(agent, actor: person(subject))
      end)

      replaced = signed_mcp(c, call_rpc("polls_list", %{"fleet_id" => @fleet}))
      assert replaced.status == 403
      assert replaced.body["error"]["code"] == "agent_not_paired"
    end
  end

  test "the budget is spent before the sign-in server is asked, even while it is down", c do
    # An hour's window, so a run that crosses a minute mark keeps its count.
    budget = Application.fetch_env!(:keyfleet, :mcp_rate_limit)
    on_exit(fn -> Application.put_env(:keyfleet, :mcp_rate_limit, budget) end)
    Application.put_env(:keyfleet, :mcp_rate_limit, Keyword.put(budget, :window_seconds, 3600))
    subject = account!()
    token = connect!(subject, @agent_scopes)
    test = self()

    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
      send(test, :signer_asked)
      conn |> put_status(503) |> Req.Test.json(%{})
    end)

    statuses = for _ <- 1..121, do: mcp(rpc("tools/list"), token, c)

    for refused <- Enum.take(statuses, 120) do
      assert refused.status == 503
      assert error(refused)["code"] == "siwa_request_failed"
    end

    assert List.last(statuses).status == 429
    assert signer_asks() == 120
  end

  # Costly failure: a caller that hasn't proved who it is has its body
  # decoded, so a made-up token buys the memory of decoding 742 KiB, once for
  # each connection it holds open.
  test "a call's body is decoded only once its caller is proved", c do
    token = connect!(account!(), @identity_scope)
    too_long = Jason.encode!(%{"x" => String.duplicate("a", 742 * 1024)})
    bodies = ["{", "[]", "1", "", too_long]
    json = [{"content-type", "application/json"}]

    post = fn headers, body ->
      answer = Req.post!(c.app <> "/mcp", headers: headers, body: body, retry: false)
      {answer.status, outcome(answer.body)}
    end

    for headers <- [json, [{"authorization", "Bearer made-up"} | json]], body <- bodies do
      assert post.(headers, body) == {401, "connection_required"}
    end

    assert Enum.map(bodies, &post.([{"authorization", "Bearer " <> token} | json], &1)) == [
             {400, "bad_request"},
             {400, "batch_not_supported"},
             {400, "bad_request"},
             {400, "bad_request"},
             {413, "request_entity_too_large"}
           ]

    # A signature covers the bytes read, which are decoded once it verifies;
    # a body too long to read whole never reaches the sign-in server.
    signed = fn signed_body ->
      SignedAgentHelpers.sign(
        c.signer,
        c.secret,
        Siwa.Contract.authority(c.app),
        "POST",
        "/mcp",
        signed_body
      ).headers
      |> Map.drop(["cookie", "authorization"])
      |> Map.to_list()
    end

    assert post.(signed.(too_long), too_long) == {413, "request_entity_too_large"}
    refute_received {:broker_payload, _payload}
    assert post.(signed.("[]"), "{") == {401, "http_signature_invalid"}
    assert post.(signed.("{"), "{") == {400, "bad_request"}
    assert post.(signed.("[]"), "[]") == {400, "batch_not_supported"}
  end

  describe "a pairing that ends while a tool runs" do
    test "replaces the answer when the pairing ends", c do
      subject = account!()
      agent = pair!(subject, c.signer.address)
      token = connect!(subject, @agent_scopes, c.signer.address)

      during_polls_list(fn ->
        :ok = RegentAgents.unpair_agent!(agent, actor: person(subject))
      end)

      replaced = call_conn(token, "polls_list", %{fleet_id: @fleet}, c)
      assert replaced.status == 403
      assert error(replaced)["code"] == "agent_not_paired"
    end

    test "replaces the answer when the identity is paired to someone else meanwhile", c do
      subject = account!()
      agent = pair!(subject, c.signer.address)
      token = connect!(subject, @agent_scopes, c.signer.address)
      other = account!()

      during_polls_list(fn ->
        :ok = RegentAgents.unpair_agent!(agent, actor: person(subject))
        pair!(other, c.signer.address)
      end)

      replaced = call_conn(token, "polls_list", %{fleet_id: @fleet}, c)
      assert replaced.status == 403
      assert error(replaced)["code"] == "agent_not_paired"
    end
  end

  # One read for each record's Answer, once where it answers and once where it
  # refuses: the connector's answer is the signed request's body, and its
  # refusal the signed request's code and words.
  test "each agent tool answers and refuses as its signed request does", c do
    subject = account!()
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes, c.signer.address)
    manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

    calls =
      for fleet <- [@fleet, "no_such_fleet"],
          {name, input} <- [
            {"rooms_list", %{"fleet_id" => fleet}},
            {"dms_list", %{"fleet_id" => fleet, "token_id" => "1"}},
            {"polls_list", %{"fleet_id" => fleet}},
            {"projects_list", %{"fleet_id" => fleet}},
            {"fleets_doctor", %{"fleet_id" => fleet}},
            {"keys_show", %{"fleet_id" => fleet, "token_id" => "1"}},
            {"keys_agents", %{"fleet_id" => fleet}},
            {"fleets_show", %{"fleet_id" => fleet}},
            {"publications_list", %{"fleet_id" => fleet, "project" => "main"}},
            {"code_pushes", %{"fleet_id" => fleet, "project" => "main"}},
            {"code_file",
             %{
               "fleet_id" => fleet,
               "project" => "main",
               "commit" => String.duplicate("a", 40),
               "path" => "lib/app.ex"
             }},
            {"notebooks_list", %{"fleet_id" => fleet, "project" => "main"}},
            {"notebooks_page",
             %{"fleet_id" => fleet, "project" => "main", "notebook_id" => "nb-0123456789abcdef"}},
            {"workspace_packet",
             %{"fleet_id" => fleet, "project" => "general", "ids" => ["goal#1"]}},
            {"workspace_pin", pin(fleet)},
            {"workspace_unpin", pin(fleet)},
            {"rooms_post", post(fleet, "general")},
            {"rooms_post", post(fleet, "people")}
          ],
          do: {name, input}

    for {name, input} <- calls ++ [{"agents_profile", %{}}, {"account_points", %{}}] do
      http = http_twin(c, manifest[name], input)
      over_mcp = result(call(token, name, input, c))

      if http.status in 200..299 do
        assert %{"isError" => false, "structuredContent" => answer} = over_mcp, name
        assert comparable(answer) == comparable(http.body), name
      else
        assert %{"isError" => true, "content" => [%{"text" => text}]} = over_mcp, name
        assert Jason.decode!(text)["error"] == http.body["error"], name
      end
    end
  end

  # What the live feed sent after a cursor is one read at every door: the
  # agent's own signed request, /mcp signed by the agent and the connector
  # answer the same events, oldest first, each with the cursor of its own
  # settled moment, thirty seconds before it read. The posts are made older
  # instead of the test waiting (`Keyfleet.FeedHelpers`). Input the tool
  # can't take, a cursor that is no string or a name it hasn't, is refused at
  # /mcp before it runs, with the signed request's code, as every tool's is
  # (`KeyfleetWeb.ToolErrors`).
  test "events_missed answers and refuses as its signed request does", c do
    subject = "did:privy:connector-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    Accounts.register_verified!(subject, wallet, [wallet], actor: %Actors.System{})
    holds!(2, wallet)
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes, c.signer.address)
    manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

    from = Keyfleet.Feed.id(FeedHelpers.database_clock())

    holder =
      Keyfleet.PairingHelpers.agent_for!(%Actors.Human{
        human_account_id: 1,
        wallet_addresses: [@owner]
      })

    posted =
      for body <- ["The hull is sound", "@Key 2 check the hull"] do
        Rooms.send_message!(
          %{fleet_id: @fleet, slug: "general", body: body, idempotency_key: Ecto.UUID.generate()},
          actor: holder
        )
      end

    FeedHelpers.age!()
    cursor = FeedHelpers.earlier(from)

    for input <- [%{"cursor" => cursor}, %{"cursor" => 5}, %{"cursor" => cursor, "after" => "1"}] do
      http = http_twin(c, manifest["events_missed"], input)

      for over_mcp <- [
            result(signed_call(c, "events_missed", input)),
            result(call(token, "events_missed", input, c))
          ] do
        if input == %{"cursor" => cursor} do
          assert http.status == 200
          assert %{"isError" => false, "structuredContent" => answer} = over_mcp
          assert Map.delete(answer, "cursor") == Map.delete(http.body, "cursor")
          assert Enum.map(answer["events"], & &1["id"]) == Enum.map(posted, & &1.id)

          assert String.to_integer(answer["cursor"]) >=
                   String.to_integer(http.body["cursor"])
        else
          assert http.status == 422
          assert %{"isError" => true, "content" => [%{"text" => text}]} = over_mcp
          assert Jason.decode!(text)["error"]["code"] == http.body["error"]["code"]
        end
      end
    end
  end

  # A season tool runs its signed request's code: through the connector and
  # over /mcp signed by the agent it answers what the request answers, and
  # refuses with its code and words. The agent acts as its person's Key 2;
  # Key 1's pick for the season taking picks is never shown to it.
  test "each season tool answers and refuses as its signed request does", c do
    subject = "did:privy:connector-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    Accounts.register_verified!(subject, wallet, [wallet], actor: %Actors.System{})
    holds!(2, wallet)
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes, c.signer.address)
    manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    played!(owner)
    Seasons.pick!(@fleet, 3, %{product: "SOL-USD", reason: "Not yet seen"}, actor: owner)
    pick = %{"fleet_id" => @fleet, "product" => "SOL-USD", "reason" => "Mine"}

    for {name, input} <- [
          {"seasons_pick", pick},
          {"seasons_pick", %{pick | "product" => "DOGE-USD"}},
          {"seasons_pick", %{pick | "product" => "sol-usd"}},
          {"seasons_pick", %{pick | "reason" => "Line one\nline two"}},
          {"seasons_pick", %{pick | "fleet_id" => "no_such_fleet"}},
          {"seasons_show", %{"fleet_id" => @fleet}},
          {"seasons_show", %{"fleet_id" => "no_such_fleet"}},
          {"seasons_list", %{"fleet_id" => @fleet}},
          {"seasons_list", %{"fleet_id" => @fleet, "before" => "1"}},
          {"seasons_list", %{"fleet_id" => @fleet, "before" => "0"}},
          {"seasons_list", %{"fleet_id" => "no_such_fleet"}},
          {"seasons_coins", %{}}
        ],
        over_mcp <- [result(call(token, name, input, c)), result(signed_call(c, name, input))] do
      http = http_twin(c, manifest[name], input)

      if http.status in 200..299 do
        assert %{"isError" => false, "structuredContent" => answer} = over_mcp, name
        assert answer == http.body, name
      else
        assert %{"isError" => true, "content" => [%{"text" => text}]} = over_mcp, name
        assert Jason.decode!(text)["error"] == http.body["error"], name
      end
    end

    now = http_twin(c, manifest["seasons_show"], %{"fleet_id" => @fleet}).body
    assert %{"key" => 2, "reason" => "Mine"} = now["taking_picks"]["my_pick"]
    assert now["taking_picks"]["keys_locked"] == 2
    refute Jason.encode!(now) =~ "Not yet seen"

    # A reason longer than 500 characters is refused at every door, counted
    # in characters as the signed request counts it, and nothing is written;
    # 500 emoji are 500 characters.
    too_long = %{pick | "reason" => String.duplicate("r", 501)}

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             result(call(token, "seasons_pick", too_long, c))

    assert %{"code" => "invalid_request", "hint" => "reason is at most 500 characters;" <> _} =
             Jason.decode!(text)["error"]

    assert http_twin(c, manifest["seasons_pick"], too_long).body["error"]["code"] ==
             "invalid_pick"

    emoji = %{pick | "reason" => String.duplicate("😀", 500)}
    assert %{"isError" => false} = result(call(token, "seasons_pick", emoji, c))
    assert http_twin(c, manifest["seasons_pick"], emoji).status == 200

    # Half an emoji can't be carried as JSON text: the connector refuses the
    # call and the signed request its body, and the pick stays as it was.
    half = ~s("reason":"\\ud83d")
    input = ~s({"fleet_id":"#{@fleet}","product":"SOL-USD",#{half}})

    refused =
      mcp_text(
        ~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"seasons_pick","arguments":{"input":#{input}}}}),
        token,
        c
      )

    assert refused.status == 400
    assert error(refused)["code"] == "bad_request"

    path = "/api/v1/agent/fleets/#{@fleet}/seasons/pick"
    not_json = signed_text(c, "POST", path, ~s({"product":"SOL-USD",#{half}}))
    assert not_json.status == 422
    assert not_json.body["error"]["code"] == "invalid_request"

    assert http_twin(c, manifest["seasons_show"], %{"fleet_id" => @fleet}).body["taking_picks"][
             "my_pick"
           ]["reason"] == emoji["reason"]
  end

  # An agent whose person holds no Key of the fleet reads its settled seasons
  # and the products open to picks, and neither reads the seasons now nor
  # picks; an app that hasn't paired runs none of the four.
  test "a season tool refuses a non-member as its signed request does, and an unpaired app",
       c do
    {:ok, outsider} = Siwa.LocalSigner.new()
    subject = account!()
    pair!(subject, outsider.address)
    token = connect!(subject, @agent_scopes, outsider.address)
    played!(%Actors.Human{human_account_id: 1, wallet_addresses: [@owner]})
    pick = %{"fleet_id" => @fleet, "product" => "SOL-USD"}

    for name <- ["seasons_show", "seasons_pick"] do
      input = if name == "seasons_pick", do: pick, else: %{"fleet_id" => @fleet}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               result(call(token, name, input, c))

      assert Jason.decode!(text)["error"]["code"] == "season_needs_key", name
    end

    assert %{"isError" => false, "structuredContent" => %{"seasons" => [%{"number" => 1}]}} =
             result(call(token, "seasons_list", %{"fleet_id" => @fleet}, c))

    assert %{"isError" => false, "structuredContent" => %{"products" => products}} =
             result(call(token, "seasons_coins", %{}, c))

    assert Enum.sort(products) == ["SOL-USD", "USDC"]

    unpaired = connect!(account!(), @agent_scopes)

    for {name, input} <- [
          {"seasons_show", %{"fleet_id" => @fleet}},
          {"seasons_pick", pick},
          {"seasons_list", %{"fleet_id" => @fleet}},
          {"seasons_coins", %{}}
        ],
        do: assert(not_paired?(call(unpaired, name, input, c)), name)
  end

  # A picture is larger than a signed request can carry, so it goes in two
  # steps, as the browser tools send it: the start answers an address on this
  # site, and the upload sends the bytes there as base64.
  test "the picture tools set and remove the agent's picture", c do
    subject = account!()
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes, c.signer.address)
    test = self()

    Req.Test.stub(Keyfleet.Agents.AvatarBucket, fn conn ->
      send(test, {:bucket, conn.method})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    picture = png(64, 64)

    declared = %{
      "sha256" => :sha256 |> :crypto.hash(picture) |> Base.encode16(case: :lower),
      "byte_size" => byte_size(picture),
      "content_type" => "image/png"
    }

    started = result(call(token, "agents_avatar_start", declared, c))
    assert %{"isError" => true, "content" => [%{"text" => text}]} = started
    assert Jason.decode!(text)["error"]["code"] == "profile_not_found"

    joined = %{"name" => "Claude", "declared_harness" => "claude"}
    assert %{"isError" => false} = result(call(token, "agents_join", joined, c))

    refused = result(call(token, "agents_avatar_start", %{declared | "byte_size" => 0}, c))
    assert %{"isError" => true, "content" => [%{"text" => text}]} = refused
    assert Jason.decode!(text)["error"]["code"] == "invalid_avatar"

    assert %{"isError" => false, "structuredContent" => address} =
             result(call(token, "agents_avatar_start", declared, c))

    assert %{"method" => "PUT", "content_type" => "image/png", "upload_url" => url} = address
    upload = fn input -> result(call(token, "agents_avatar_upload", input, c)) end
    bytes = %{"upload_url" => url, "content_type" => "image/png"}

    for {input, code} <- [
          {Map.put(bytes, "bytes_base64", Base.encode64(png(64, 65))), "avatar_mismatch"},
          {Map.put(bytes, "bytes_base64", "not base64!"), "invalid_request"},
          {%{bytes | "content_type" => "image/webp"}
           |> Map.put("bytes_base64", Base.encode64(picture)), "avatar_mismatch"},
          {%{
             bytes
             | "upload_url" => String.replace(url, URI.parse(url).host, "elsewhere.example")
           }
           |> Map.put("bytes_base64", Base.encode64(picture)), "avatar_upload_expired"},
          {%{bytes | "upload_url" => url <> "?x=1"}
           |> Map.put("bytes_base64", Base.encode64(picture)), "avatar_upload_expired"}
        ] do
      assert %{"isError" => true, "content" => [%{"text" => text}]} = upload.(input)
      assert Jason.decode!(text)["error"]["code"] == code, inspect(input)
    end

    refute_received {:bucket, _method}

    # The address's path alone is taken too, as the browser tool takes it.
    path = URI.parse(url).path

    assert %{"isError" => false, "structuredContent" => %{"avatar_url" => avatar}} =
             upload.(
               %{bytes | "upload_url" => path}
               |> Map.put("bytes_base64", Base.encode64(picture))
             )

    assert is_binary(avatar)
    assert_received {:bucket, "PUT"}

    # So is the address as a browser resolves it: any case of host, dot
    # segments, an empty question, and base64 broken into lines.
    %URI{host: host} = URI.parse(url)

    written =
      String.replace(url, host, String.upcase(host))
      |> String.replace("/avatar/", "/x/../avatar/")

    wrapped =
      picture |> Base.encode64() |> String.graphemes() |> Enum.chunk_every(20) |> Enum.join("\n")

    assert %{"isError" => false, "structuredContent" => %{"avatar_url" => avatar}} =
             upload.(
               %{bytes | "upload_url" => written <> "?"}
               |> Map.put("bytes_base64", wrapped)
             )

    assert %{"structuredContent" => %{"profile" => %{"avatar_url" => ^avatar}}} =
             result(call(token, "agents_profile", %{}, c))

    # The largest picture fits the connector's call in base64 lines of 64
    # ending in CRLF, the most an encoder's breaks add to it.
    largest =
      picture <> :binary.copy(<<0>>, Keyfleet.Agents.Avatar.max_bytes() - byte_size(picture))

    assert %{"isError" => false, "structuredContent" => %{"upload_url" => largest_url}} =
             result(
               call(
                 token,
                 "agents_avatar_start",
                 %{
                   declared
                   | "sha256" => :sha256 |> :crypto.hash(largest) |> Base.encode16(case: :lower),
                     "byte_size" => byte_size(largest)
                 },
                 c
               )
             )

    lines = Regex.scan(~r/.{1,64}/, Base.encode64(largest)) |> Enum.map_join(&(hd(&1) <> "\r\n"))

    assert %{"isError" => false} =
             upload.(%{bytes | "upload_url" => largest_url} |> Map.put("bytes_base64", lines))

    assert %{"isError" => false, "structuredContent" => %{"avatar_url" => nil}} =
             result(call(token, "agents_avatar_remove", %{}, c))
  end

  # A PNG's signature and header chunk, which say its size; enough for the
  # size check, which reads no further.
  defp png(width, height) do
    header = <<width::32, height::32, 8, 6, 0, 0, 0>>
    chunk = "IHDR" <> header
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32>> <> chunk <> <<:erlang.crc32(chunk)::32>>
  end

  defp pin(fleet),
    do: %{"fleet_id" => fleet, "project" => "main", "place" => "code", "target" => "a"}

  # A post by an agent whose person holds no Key, refused in every room.
  defp post(fleet, slug),
    do: %{"fleet_id" => fleet, "slug" => slug, "body" => "Standing by", "idempotency_key" => slug}

  # Nothing of a coming-soon fleet is read or written, a sync's check-in
  # included: every tool naming one is refused as its signed request is.
  test "a tool naming a coming-soon fleet is refused as its signed request is", c do
    subject = account!()
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes, c.signer.address)
    manifest = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

    for {name, input} <- [
          {"rooms_list", %{"fleet_id" => @coming_soon}},
          {"mutes_list", %{"fleet_id" => @coming_soon}},
          {"fleets_sync",
           %{
             "fleet_id" => @coming_soon,
             "rooms" => [%{"slug" => "general", "after_seq" => 0}],
             "graph" => %{"after_seq" => 0, "project" => "general"},
             "proposals" => %{"after_seq" => 0},
             "run" => %{"kind" => "session"}
           }},
          {"workspace_create",
           %{
             "fleet_id" => @coming_soon,
             "as_key" => 1,
             "command_id" => Ecto.UUID.generate(),
             "project" => "main",
             "type" => "task",
             "data" => %{"title" => "Coming soon"}
           }}
        ] do
      http = http_twin(c, manifest[name], input)
      assert http.status == 404, name

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               result(call(token, name, input, c)),
             name

      assert Jason.decode!(text)["error"] == http.body["error"], name
      assert http.body["error"]["code"] == "fleet_coming_soon", name
    end

    refute Keyfleet.Repo.exists?(Keyfleet.Agents.CheckIn)

    # What anyone reads of a fleet is answered for a coming-soon one too.
    input = %{"fleet_id" => @coming_soon}
    http = http_twin(c, manifest["fleets_show"], input)
    assert http.status == 200
    assert %{"isError" => false} = result(call(token, "fleets_show", input, c))
  end

  # The doctor also says how its caller signed in: a signed request by its
  # wallet's signature, the connector by its connected app, each with its own
  # expiry. Everything else it answers is the same.
  # Two reads made a moment apart differ only in when they were made and in
  # the sign-in's own expiry.
  defp comparable(answer), do: answer |> Map.delete("generated_at") |> same_sign_in()

  defp same_sign_in(%{"agent" => %{} = agent} = answer),
    do: %{answer | "agent" => Map.drop(agent, ["sign_in_expires_at", "verification_method"])}

  defp same_sign_in(answer), do: answer

  # Runs `fun` as the agent tools' next action starts, inside the request.
  defp during_polls_list(fun) do
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ash, Ash.Domain.Info.short_name(KeyfleetWeb.AgentTools), :action, :start],
      fn _event, _measurements, _metadata, _config ->
        :telemetry.detach(id)
        fun.()
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Switches the connector on for one test as config/runtime.exs does with
  # KEYFLEET_CLAUDE_CONNECTOR_ENABLED=true, and starts its sign-in store in
  # this test's transaction; everything is put back after. The hosted signer
  # answers each app's identity with the wallet it was connected with, or one
  # of its own.
  defp connector_on do
    origin = "http://127.0.0.1:4002"

    put_env(
      :keyfleet,
      Keyfleet.OAuth,
      Keyword.merge(Application.fetch_env!(:keyfleet, Keyfleet.OAuth),
        enabled?: true,
        issuer: origin,
        resource: origin <> "/mcp"
      )
    )

    put_env(
      :regent_mcp_agents,
      :config,
      Keyword.merge(Application.fetch_env!(:regent_mcp_agents, :config),
        enabled?: true,
        hosted_signer: [base_url: "https://siwa.test", key: @site_key]
      )
    )

    put_env(:regent_agents, :hosted_pairing, [:claude])
    put_env(:regent_mcp_agents, :req_options, plug: {Req.Test, RegentMCPAgents.HostedSigner})
    keep_env(:regent_oauth, :site)
    keep_env(:boruta, Boruta.Oauth)

    :ok = RegentOAuth.configure(Keyfleet.OAuth)
    :ok = RegentMCPAgents.configure!()

    start_supervised!(%{
      id: @wallets,
      start: {Agent, :start_link, [fn -> %{} end, [name: @wallets]]}
    })

    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
      {:ok, body, conn} = read_body(conn)
      key = Jason.decode!(body)["identity_key"]
      wallet = Agent.get(@wallets, &Map.get(&1, key, identity_wallet(key)))
      Req.Test.json(conn, %{"address" => wallet})
    end)
  end

  defp put_env(app, key, value) do
    keep_env(app, key)
    Application.put_env(app, key, value)
  end

  defp keep_env(app, key) do
    old = Application.fetch_env(app, key)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  # A person's verified account; a fresh one each time, so the hosted wallet
  # each test's identity keeps is asked for again.
  defp account! do
    subject = "did:privy:connector-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    Accounts.register_verified!(subject, wallet, [wallet], actor: %Actors.System{})
    subject
  end

  defp pair!(subject, wallet) do
    %{code: code} = RegentAgents.issue_pairing_code!(actor: person(subject))
    RegentAgents.pair_agent!(code, "Claude", :claude, actor: %RegentAgents.Agent{wallet: wallet})
    [agent] = RegentAgents.list_my_agents!(actor: person(subject))
    agent
  end

  defp person(subject), do: %RegentAgents.Person{privy_user_id: subject}

  # The fleet's seasons played by its turns: season 1 settled with a pick of
  # `owner`'s Key, season 2 under way and season 3 taking picks.
  defp played!(owner) do
    [b0, b1, b2 | _] = SeasonHelpers.boundaries(2)
    SeasonHelpers.coinbase!(%{"SOL-USD" => [{b1, "100"}, {b2, "97"}]})
    SeasonHelpers.turn!(@fleet, b0)
    Seasons.pick!(@fleet, 1, %{product: "SOL-USD", reason: "Fast chain"}, actor: owner)
    SeasonHelpers.turn!(@fleet, b1)
    SeasonHelpers.turn!(@fleet, b2)
  end

  defp holds!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("b", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # An app connected by `subject`, as consent leaves it: its access token.
  # Given a wallet, the app's hosted identity keeps it.
  defp connect!(subject, scope, wallet \\ nil),
    do: connect_app!(subject, scope, wallet).access

  # The same app as its client id and the access and refresh tokens it holds.
  defp connect_app!(subject, scope, wallet) do
    register =
      conn(:post, "/oauth/register", %{
        "client_name" => "Claude",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })
      |> put_req_header("accept", "application/json")
      |> @endpoint.call([])

    assert register.status == 201, register.resp_body
    client = Boruta.ClientsAdapter.get_client(Jason.decode!(register.resp_body)["client_id"])

    {:ok, token} =
      RegentOAuth.AccessTokens.create(%{client: client, sub: subject, scope: scope},
        refresh_token: true
      )

    if wallet, do: Agent.update(@wallets, &Map.put(&1, key(subject, client.id), wallet))
    %{client_id: client.id, access: token.value, refresh: token.refresh_token}
  end

  # The access token the token endpoint gives for the app's refresh token.
  defp refresh!(app) do
    params = %{
      "grant_type" => "refresh_token",
      "client_id" => app.client_id,
      "refresh_token" => app.refresh,
      "resource" => RegentOAuth.resource()
    }

    refreshed =
      conn(:post, "/oauth/token", params)
      |> put_req_header("accept", "application/json")
      |> @endpoint.call([])

    assert refreshed.status == 200, refreshed.resp_body
    Jason.decode!(refreshed.resp_body)["access_token"]
  end

  defp key(subject, client), do: RegentMCPAgents.identity_key("keyfleet", subject, client)
  defp identity_wallet(key), do: "0x" <> binary_part(key, 0, 40)

  defp mcp(body, token, c), do: mcp_text(Jason.encode!(body), token, c)

  defp mcp_text(text, token, c) do
    conn =
      conn(:post, "/mcp", text)
      |> Map.put(:remote_ip, c.from)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    @endpoint.call(conn, [])
  end

  defp call_conn(token, name, input, c), do: mcp(call_rpc(name, input), token, c)

  defp call_rpc(name, input),
    do: rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})

  # The same JSON-RPC message, signed by the agent's own key and sent with no token.
  defp signed_mcp(c, body), do: signed(c, "POST", "/mcp", body)

  defp signed_call(c, name, input), do: signed_mcp(c, call_rpc(name, input)).body

  defp fleet_tools do
    for domain <- [KeyfleetWeb.AgentTools, Keyfleet.Graph],
        tool <- AshAi.Info.tools(domain),
        do: to_string(tool.name)
  end

  defp call(token, name, input, c), do: json(call_conn(token, name, input, c))

  defp tool_names(token, c),
    do: Enum.map(json(mcp(rpc("tools/list"), token, c))["result"]["tools"], & &1["name"])

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  # The tool's HTTP twin: the same agent's signed request, or for what anyone
  # reads, the public address with no signature.
  @public %{"fleets_show" => "/api/v1/fleets/"}

  defp http_twin(c, %{"authentication" => "public", "name" => name}, %{"fleet_id" => fleet}),
    do: Req.get!(c.app <> @public[name] <> fleet, retry: false, redirect: false)

  defp http_twin(c, browser_tool, input) do
    {:ok, method, path, body} = Keyfleet.Capabilities.request(browser_tool, input)
    signed(c, method, path, body)
  end

  # The same agent's own signed request, through the site served on a port.
  defp signed(c, method, path, body),
    do: signed_text(c, method, path, body && Jason.encode!(body))

  defp signed_text(c, method, path, text) do
    request =
      SignedAgentHelpers.sign(
        c.signer,
        c.secret,
        Siwa.Contract.authority(c.app),
        method,
        path,
        text
      )

    Req.request!(
      method: method |> String.downcase() |> String.to_existing_atom(),
      url: c.app <> request.path,
      headers: Map.drop(request.headers, ["cookie", "authorization"]),
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  defp signer_asks do
    receive do
      :signer_asked -> 1 + signer_asks()
    after
      0 -> 0
    end
  end

  defp result(%{"result" => result}), do: result

  # What a signed call was answered: the code a refusal names, or what it reached.
  defp outcome(%{"error" => %{"code" => code}}), do: code
  defp outcome(%{"result" => %{"tools" => [_ | _]}}), do: :tools
  defp outcome(answer), do: answer

  # A tool's refusal of an app that hasn't paired: the error alone, no data.
  defp not_paired?(%{
         "result" => %{"isError" => true, "content" => [%{"text" => text}]} = result
       }),
       do:
         not Map.has_key?(result, "structuredContent") and
           Jason.decode!(text)["error"]["code"] == "agent_not_paired"

  defp not_paired?(_answer), do: false

  defp error(conn), do: json(conn)["error"]
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp new_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
