defmodule KeyfleetWeb.McpConnectorTest do
  # The Claude connector's address, /mcp, through this site's own endpoint,
  # router, sign-in, pairings and tools, with the connector switched on:
  # - who a request runs as follows its token's permissions and its identity's
  #   pairing: the fleet tools only for the agent paired with that same account,
  #   and never a wallet's tools;
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
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @coming_soon "fleet_tech_accelerant"
  @owner "0x" <> String.duplicate("a", 40)
  @site_key String.duplicate("k", 32)
  @agent_scopes "regent.identity.manage keyfleet.agent"

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

    # The hosted identity's wallet is a local signer's, so the same agent can
    # also sign its own requests to the site.
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    app = SignedAgentHelpers.serve!(:product, &@endpoint.call(&1, @endpoint.init(&2)))
    connector_on(signer.address)

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
      token = connect!(subject)

      assert Enum.sort(tool_names(token, c)) == Enum.sort(RegentMCPAgents.Tools.names())
      assert %{"error" => _} = call(token, "polls_list", %{fleet_id: @fleet}, c)
    end

    test "the agent permission with the identity paired to this account lists every fleet tool, the workspace's writes included, and no wallet tool",
         c do
      subject = account!()
      pair!(subject, c.signer.address)
      token = connect!(subject, @agent_scopes)
      listed = tool_names(token, c)

      fleet_tools =
        for domain <- [KeyfleetWeb.AgentTools, Keyfleet.Graph],
            tool <- AshAi.Info.tools(domain),
            do: to_string(tool.name)

      assert "workspace_create" in fleet_tools
      assert Enum.sort(listed) == Enum.sort(RegentMCPAgents.Tools.names() ++ fleet_tools)

      for wallet_tool <- ["keys_claim", "proposals_vote"] do
        refute wallet_tool in listed
        assert %{"error" => _} = call(token, wallet_tool, %{fleet_id: @fleet}, c)
      end
    end

    test "the agent permission with the identity paired to another account, or to no one, stays the app",
         c do
      subject = account!()
      token = connect!(subject, @agent_scopes)

      assert Enum.sort(tool_names(token, c)) == Enum.sort(RegentMCPAgents.Tools.names())

      pair!(account!(), c.signer.address)
      assert Enum.sort(tool_names(token, c)) == Enum.sort(RegentMCPAgents.Tools.names())
      assert %{"error" => _} = call(token, "polls_list", %{fleet_id: @fleet}, c)
    end

    test "a request without a token is asked to connect", c do
      refused = mcp(rpc("tools/list"), nil, c)
      assert refused.status == 401
      assert error(refused)["code"] == "connection_required"
      assert [_challenge] = get_resp_header(refused, "www-authenticate")
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

  describe "a pairing that ends while a tool runs" do
    test "replaces the answer when the pairing ends", c do
      subject = account!()
      agent = pair!(subject, c.signer.address)
      token = connect!(subject, @agent_scopes)

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
      token = connect!(subject, @agent_scopes)
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
    token = connect!(subject, @agent_scopes)
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
            {"fleets_show", %{"fleet_id" => fleet}},
            {"publications_list", %{"fleet_id" => fleet, "project" => "main"}},
            {"code_pushes", %{"fleet_id" => fleet, "project" => "main"}},
            {"notebooks_list", %{"fleet_id" => fleet, "project" => "main"}},
            {"workspace_pin", pin(fleet)},
            {"workspace_unpin", pin(fleet)}
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

  # A picture is larger than a signed request can carry, so it goes in two
  # steps, as the browser tools send it: the start answers an address on this
  # site, and the upload sends the bytes there as base64.
  test "the picture tools set and remove the agent's picture", c do
    subject = account!()
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes)
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

  # Nothing of a coming-soon fleet is read or written, a sync's check-in
  # included: every tool naming one is refused as its signed request is.
  test "a tool naming a coming-soon fleet is refused as its signed request is", c do
    subject = account!()
    pair!(subject, c.signer.address)
    token = connect!(subject, @agent_scopes)
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
  # answers every account with `wallet`.
  defp connector_on(wallet) do
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
    for key <- [RegentOAuth.Repo, :site, :prefix], do: keep_env(:regent_oauth, key)
    keep_env(:boruta, Boruta.Oauth)

    :ok = RegentOAuth.configure(Keyfleet.OAuth)
    :ok = RegentMCPAgents.configure!()

    Application.put_env(
      :regent_oauth,
      RegentOAuth.Repo,
      Keyword.put(
        Application.fetch_env!(:regent_oauth, RegentOAuth.Repo),
        :pool,
        Ecto.Adapters.SQL.Sandbox
      )
    )

    start_supervised!(RegentOAuth.Repo)
    oauth = Ecto.Adapters.SQL.Sandbox.start_owner!(RegentOAuth.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(oauth) end)

    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
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

  # An app connected by `subject`, as consent leaves it: its access token.
  defp connect!(subject, scope \\ "regent.identity.manage") do
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
      RegentOAuth.AccessTokens.create(%{client: client, sub: subject, scope: scope}, [])

    token.value
  end

  defp mcp(body, token, c) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> Map.put(:remote_ip, c.from)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    @endpoint.call(conn, [])
  end

  defp call_conn(token, name, input, c),
    do: mcp(rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}}), token, c)

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
  defp signed(c, method, path, body) do
    request =
      SignedAgentHelpers.sign(c.signer, c.secret, method, path, body && Jason.encode!(body))

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
  defp error(conn), do: json(conn)["error"]
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp new_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
