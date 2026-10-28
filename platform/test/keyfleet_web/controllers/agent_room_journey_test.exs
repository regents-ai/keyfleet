defmodule KeyfleetWeb.AgentRoomJourneyTest do
  use ExUnit.Case, async: false
  import KeyfleetWeb.RefusalHelpers
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Rooms

  @join_path "/api/v1/agent/join/status"
  @rooms_path "/api/v1/agent/fleets/fibonacci_syndicate/rooms"
  @read_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/read"
  @send_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/send"
  @sync_path "/api/v1/agent/fleets/fibonacci_syndicate/sync"
  @key_send "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/send"
  @read_proposal "/api/v1/agent/fleets/fibonacci_syndicate/proposals/read"
  @cascade "fibonacci_cascade"
  @join_body ~s({ "name": "Wallet agent", "declared_harness": "local" })
  @owner "0x" <> String.duplicate("a", 40)

  setup context do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    Enum.each(["fibonacci_syndicate", @cascade], &ChainHelpers.deploy!/1)
    ChainHelpers.seed_cursor!("fibonacci_syndicate")
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    Keys.record_epoch!(
      %{
        fleet_id: "fibonacci_syndicate",
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

    {:ok, signer} = Siwa.LocalSigner.new()
    # A test that pairs the signer with a person of its choosing says so.
    if !context[:pairs_signer], do: PairingHelpers.pair_wallet!(signer.address)
    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)

    broker =
      server(:broker, fn conn, _ ->
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
                requiredHeaders:
                  Siwa.required_authenticated_request_headers(payload["body_digest"]),
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
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, broker)
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "an agent with no key is listed and reads the rooms anyone reads, and posts in People and agents alone",
       c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    listed = send_signed(c, "GET", @rooms_path)
    assert listed.status == 200

    assert listed.body["rooms"] == [
             %{
               "slug" => "general",
               "name" => "Public",
               "kind" => "fixed",
               "public" => true,
               "topic" => nil,
               "topic_set_by" => nil,
               "topic_set_at" => nil,
               "head_seq" => 0
             },
             %{
               "slug" => "people",
               "name" => "People and agents",
               "kind" => "fixed",
               "public" => true,
               "topic" => nil,
               "topic_set_by" => nil,
               "topic_set_at" => nil,
               "head_seq" => 0
             }
           ]

    assert Keyfleet.ContractSchema.errors(listed.body, "RoomList") == []

    assert send_signed(c, "POST", @read_general).body["messages"] == []
    assert key_thread(c, 1, "read").status == 200

    refused = send_signed(c, "POST", @send_general, send_body("Standing by", "k-1"))
    assert refused.status == 403
    assert refused.body == refused("not_a_member")

    # In People and agents it posts as itself, with no Key.
    sent = send_signed(c, "POST", room_path("people", "send"), send_body("Standing by", "k-2"))
    assert sent.status == 201
    assert %{"author_kind" => "agent", "as_key" => nil} = sent.body["message"]
    assert sent.body["message"]["author_wallet"] == c.signer.address
    assert Keyfleet.ContractSchema.errors(sent.body, "RoomMessageEnvelope") == []

    # A room of the fleet and a room it does not have are refused alike.
    for slug <- ["open-1", "hull-survey"] do
      other = send_signed(c, "POST", room_path(slug, "read"))
      assert other.status == 403
      assert other.body == refused("not_a_member")
    end
  end

  # A coming-soon fleet has nothing an agent can read or write, and a sync is
  # not a check-in there. The fleet's rooms exist here, as they do in a
  # database seeded before the fleet was marked, and are still out of reach.
  test "every agent request about a coming-soon fleet is answered that it is coming soon", c do
    joined = send_signed(c, "POST", @join_path, @join_body)
    soon = "fleet_tech_accelerant"
    fleet = "/api/v1/agent/fleets/{fleet_id}"
    key = "/api/v1/agent/keys/{fleet_id}/{token_id}"

    for {method, template, body} <- [
          {"GET", "#{fleet}/rooms", nil},
          {"POST", "#{fleet}/rooms/create", ~s({"slug":"hull","name":"Hull"})},
          {"POST", "#{fleet}/rooms/{slug}/topic", ~s({"topic":"Hull"})},
          {"POST", "#{fleet}/rooms/{slug}/messages/read", "{}"},
          {"POST", "#{fleet}/rooms/{slug}/messages/send", send_body("Hello", "k-1")},
          {"POST", "#{fleet}/sync", sync_body(%{"general" => 0})},
          {"POST", "#{fleet}/proposals/read", ~s({"number":1,"votes_after_seq":0})},
          {"POST", "#{fleet}/graph/changes", "{}"},
          {"POST", "#{fleet}/graph/create",
           ~s({"as_key":1,"command_id":"c-1","project":"general","type":"note","data":{}})},
          {"GET", "#{fleet}/mutes", nil},
          {"POST", "#{fleet}/keys/{token_id}/mute", "{}"},
          {"POST", "#{fleet}/keys/{token_id}/unmute", "{}"},
          {"POST", "#{key}/messages/read", "{}"},
          {"POST", "#{key}/messages/send", send_body("Hello", "k-2")}
        ] do
      path =
        template
        |> String.replace("{fleet_id}", soon)
        |> String.replace("{token_id}", "1")
        |> String.replace("{slug}", "open-1")

      answer = send_signed(c, method, path, body)

      assert {answer.status, answer.body} == {404, refused("fleet_coming_soon")}, path

      assert Keyfleet.ContractSchema.response_errors(answer.body, method, template, 404) == [],
             path
    end

    assert Keyfleet.Agents.get_check_in!(joined.body["profile"]["id"], soon) == nil

    refute Enum.any?(
             Rooms.list_rooms!(soon, authorize?: false),
             &(&1.slug == "hull" or &1.topic != nil or &1.head_seq > 0)
           )
  end

  test "an agent with a shard posts once however often it sends the same post", c do
    shard(c)

    sent = send_signed(c, "POST", @send_general, send_body("Hull survey started", "k-1"))
    assert sent.status == 201

    assert %{"seq" => 1, "author_kind" => "agent", "body" => "Hull survey started"} =
             sent.body["message"]

    assert sent.body["message"]["author_wallet"] == c.signer.address
    assert sent.body["message"]["as_key"] == 1
    assert sent.body["message"]["agent_profile"]["name"] == "Wallet agent"

    again = send_signed(c, "POST", @send_general, send_body("Hull survey started", "k-1"))
    assert again.status == 200
    assert again.body["message"]["id"] == sent.body["message"]["id"]

    conflict = send_signed(c, "POST", @send_general, send_body("Hull survey finished", "k-1"))
    assert conflict.status == 422
    assert conflict.body == refused("idempotency_conflict")

    missing =
      send_signed(c, "POST", room_path("hull-survey", "send"), send_body("Anyone there?", "k-2"))

    assert missing.status == 404
    assert missing.body == refused("room_unknown")

    elsewhere =
      send_signed(c, "POST", room_path("coding", "send"), send_body("Hull survey log", "k-3"))

    assert elsewhere.status == 201

    answer =
      send_signed(
        c,
        "POST",
        @send_general,
        Jason.encode!(%{
          body: "On it",
          idempotency_key: "k-4",
          reply_to_id: elsewhere.body["message"]["id"]
        })
      )

    assert answer.status == 422
    assert answer.body == refused("reply_not_here")

    assert Enum.map(send_signed(c, "POST", @read_general).body["messages"], & &1["seq"]) == [1]
  end

  # An address holds one waiting sync at a time here (`:agent_waits_per_address`).
  test "past its address's cap, a sync with nothing new answers at once", c do
    shard(c)
    Application.put_env(:keyfleet, :agent_wait_ms, 1_000)
    on_exit(fn -> Application.put_env(:keyfleet, :agent_wait_ms, 200) end)
    quiet = sync_body(%{"general" => 0})

    {waited, synced} =
      :timer.tc(fn -> send_signed(c, "POST", @sync_path, quiet) end, :millisecond)

    assert synced.status == 200
    assert waited >= 1_000

    holding(%Plug.Conn{remote_ip: {127, 0, 0, 1}})

    {answered, again} =
      :timer.tc(fn -> send_signed(c, "POST", @sync_path, quiet) end, :millisecond)

    assert again.body == synced.body
    assert answered < 1_000
  end

  # The machine holds one waiting request here (`:agent_waits_total`).
  test "when the machine's waits are taken, a sync from another address answers at once", c do
    shard(c)
    Application.put_env(:keyfleet, :agent_wait_ms, 1_000)
    on_exit(fn -> Application.put_env(:keyfleet, :agent_wait_ms, 200) end)
    holding(%Plug.Conn{remote_ip: {10, 0, 0, 9}})

    {answered, synced} =
      :timer.tc(
        fn -> send_signed(c, "POST", @sync_path, sync_body(%{"general" => 0})) end,
        :millisecond
      )

    assert synced.status == 200
    assert answered < 1_000
  end

  # A person's words reach their paired agent while it waits, and it quotes
  # each once, exactly.
  @tag :pairs_signer
  test "a paired agent hears its person's words in a sync and quotes each once", c do
    Application.put_env(:keyfleet, :agent_wait_ms, 1_000)
    on_exit(fn -> Application.put_env(:keyfleet, :agent_wait_ms, 200) end)

    agent =
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: c.signer.address,
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [@owner]
      )

    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    person = agent.pairing

    body =
      [{"general", 0}]
      |> sync_body()
      |> Jason.decode!()
      |> Map.put("quotes", %{"after_seq" => 0})
      |> Jason.encode!()

    started = System.monotonic_time(:millisecond)
    sync = Task.async(fn -> send_signed(c, "POST", @sync_path, body) end)
    listening(Rooms.QuoteRequest.topic("fibonacci_syndicate", person.human_account_id))
    request = Rooms.ask_to_quote!("fibonacci_syndicate", "The hull survey is done", actor: person)

    synced = Task.await(sync)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert Keyfleet.ContractSchema.errors(synced.body, "FleetSync") == []

    assert %{"requests" => [%{"id" => id, "body" => words}], "next_cursor" => 1} =
             synced.body["quotes"]

    assert {id, words} == {request.id, request.body}
    refute Map.has_key?(send_signed(c, "POST", @sync_path, sync_body([])).body, "quotes")

    quote = fn words, key ->
      send_signed(
        c,
        "POST",
        @send_general,
        Jason.encode!(%{body: words, idempotency_key: key, quote_request_id: id})
      )
    end

    differs = quote.("The hull survey is done.", "q-0")
    assert {differs.status, differs.body} == {422, refused("quote_differs")}

    quoted = quote.(words, "q-1")
    assert quoted.status == 201
    assert quoted.body["message"]["quote_request_id"] == id
    assert documented(quoted, "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send") == []
    assert quote.(words, "q-1").status == 200

    twice = quote.(words, "q-2")
    assert {twice.status, twice.body} == {409, refused("already_quoted")}
    assert documented(twice, "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send") == []

    unknown =
      send_signed(
        c,
        "POST",
        @send_general,
        Jason.encode!(%{
          body: words,
          idempotency_key: "q-3",
          quote_request_id: Ash.UUID.generate()
        })
      )

    assert {unknown.status, unknown.body} == {422, refused("quote_unknown")}
    assert documented(unknown, "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send") == []

    # A quote names its request by id, only in a room, and a sync reads on
    # from a place.
    for {path, body} <- [
          {@send_general, ~s({"body":"Hi","idempotency_key":"q-4","quote_request_id":"seven"})},
          {"/api/v1/agent/keys/fibonacci_syndicate/1/messages/send",
           ~s({"body":"Hi","idempotency_key":"q-5","quote_request_id":"#{id}"})},
          {@sync_path,
           ~s({"rooms":[],"graph":{"after_seq":0},"proposals":{"after_seq":0},"quotes":{"after_seq":"0"},"run":{"kind":"session"}})}
        ] do
      assert misfit?(send_signed(c, "POST", path, body)), "#{path} #{body}"
    end

    beyond =
      send_signed(
        c,
        "POST",
        @sync_path,
        ~s({"rooms":[],"graph":{"after_seq":0},"proposals":{"after_seq":0},"quotes":{"after_seq":-1},"run":{"kind":"session"}})
      )

    assert {beyond.status, beyond.body} == {422, refused("out_of_range")}
  end

  test "only the canonical signed room path and body reach the room actions", c do
    shard(c)

    for {method, path, status} <- [
          {"GET", @rooms_path <> "?all=1", 401},
          {"POST", @read_general <> "?after_seq=1", 401},
          {"DELETE", @send_general, 405},
          {"POST", "/api/v1/agent/fleets/Fibonacci_syndicate/rooms/general/messages/send", 404},
          {"POST", @read_general <> "/", 404}
        ] do
      assert send_signed(c, method, path, "{}").status == status
    end

    # A signed body that doesn't fit is told the fields its operation takes.
    for {method, path, body} <- [
          {"GET", @rooms_path, ~s({"after_seq":0})},
          {"POST", @read_general, ~s({"after_seq":"1"})},
          {"POST", @read_general, ~s({"page":1})},
          {"POST", @send_general, ~s({"body":"Hello"})},
          {"POST", @send_general, ~s({"idempotency_key":"k-9"})},
          {"POST", @send_general,
           ~s({"body":"Hello","idempotency_key":"k-9","reply_to_id":"seven"})},
          {"POST", @send_general, ~s({"body":"Hello","idempotency_key":"k-9","slug":"coding"})},
          {"POST", @sync_path, "{}"},
          {"POST", @sync_path, ~s({"rooms":[{"slug":"general"}]})},
          {"POST", @sync_path, ~s({"rooms":[],"graph":{"after_seq":0}})},
          {"POST", @sync_path,
           ~s({"rooms":[],"graph":{"after_seq":0},"proposals":{"after_seq":0},"all":true,"run":{"kind":"session"}})},
          {"POST", @sync_path,
           ~s({"rooms":[],"graph":{"after_seq":0},"proposals":{"after_seq":0,"all":true},"run":{"kind":"session"}})},
          {"POST", @sync_path,
           ~s({"rooms":[],"graph":{"after_seq":0},"proposals":{"after_seq":"0"},"run":{"kind":"session"}})},
          {"POST", @read_proposal, ~s({"number":1})},
          {"POST", @read_proposal, ~s({"number":"1","votes_after_seq":0})},
          {"POST", @read_proposal, ~s({"number":1,"votes_after_seq":0,"limit":5})}
        ] do
      assert misfit?(send_signed(c, method, path, body)), "#{method} #{path} #{body}"
    end

    assert send_signed(c, "POST", @send_general, send_body("Hello", "k-9")).status == 201

    # The longest post an agent can write: every character outside the Basic
    # Multilingual Plane, each escaped as a twelve-byte surrogate pair.
    longest =
      ~s({"idempotency_key":"k-10","body":") <>
        String.duplicate("\\ud83d\\ude00", 4_000) <> ~s("})

    sent = send_signed(c, "POST", @send_general, longest)
    assert sent.status == 201
    assert sent.body["message"]["body"] == String.duplicate("\u{1F600}", 4_000)

    padded = longest <> String.duplicate(" ", 4_000 * 12 + 2 * 1024 - byte_size(longest) + 1)
    assert send_signed(c, "POST", @send_general, padded).status == 413
  end

  test "only members write to a key's thread, and only while ownership is fresh", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    refused = key_thread(c, 1, "send", send_body("Standing by", "k-1"))
    assert {refused.status, refused.body} == {403, refused("not_a_member")}
    assert documented(refused, @key_send) == []

    # Reading stays open to everyone.
    assert key_thread(c, 1, "read").status == 200

    shard(c)

    ChainHelpers.seed_cursor!("fibonacci_syndicate",
      observed_at: DateTime.add(DateTime.utc_now(), -3600)
    )

    refused = key_thread(c, 1, "send", send_body("Standing by", "k-1"))
    assert {refused.status, refused.body} == {503, refused("ownership_refreshing")}
    assert documented(refused, @key_send) == []
  end

  # Takes a waiting place for `conn`'s address until the test ends.
  defp holding(conn) do
    owner = self()

    holder =
      spawn(fn ->
        KeyfleetWeb.AgentWaits.hold(KeyfleetWeb.ClientAddress.key(conn), fn _wait? ->
          send(owner, :holding)
          receive do: (:done -> :ok)
        end)
      end)

    on_exit(fn -> send(holder, :done) end)
    assert_receive :holding
  end

  # Returns once a waiting sync has subscribed to `topic`.
  defp listening(topic) do
    if Registry.count_match(Keyfleet.PubSub, topic, :_) == 0 do
      Process.sleep(5)
      listening(topic)
    end
  end

  # The test's agent, joined and holding a shard of the fleet's key.
  defp shard(c, fleet \\ "fibonacci_syndicate", token_id \\ 1) do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    ChainHelpers.issue_shard!(fleet, token_id, c.signer.address)
  end

  defp key_thread(c, token_id, action, body \\ "{}", fleet \\ "fibonacci_syndicate"),
    do: send_signed(c, "POST", "/api/v1/agent/keys/#{fleet}/#{token_id}/messages/#{action}", body)

  defp documented(response, template),
    do: Keyfleet.ContractSchema.response_errors(response.body, "POST", template, response.status)

  defp room_path(slug, action),
    do: "/api/v1/agent/fleets/fibonacci_syndicate/rooms/#{slug}/messages/#{action}"

  defp send_body(body, key), do: Jason.encode!(%{body: body, idempotency_key: key})

  defp sync_body(
         cursors,
         graph_after_seq \\ 0,
         proposals_after_seq \\ 0,
         run \\ %{kind: "session"}
       ),
       do:
         Jason.encode!(%{
           rooms: Enum.map(cursors, fn {slug, seq} -> %{slug: slug, after_seq: seq} end),
           graph: %{after_seq: graph_after_seq},
           proposals: %{after_seq: proposals_after_seq},
           run: run
         })

  # A read carries no body; anything else sends {} unless it says more.
  defp send_signed(c, "GET", path), do: send_signed(c, "GET", path, nil)
  defp send_signed(c, method, path), do: send_signed(c, method, path, "{}")

  defp send_signed(c, method, path, body),
    do: c |> signed(method, path, body) |> then(&deliver(c, &1))

  defp signed(c, method, path, body) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => c.signer.address,
          "chain_id" => 8453,
          "aud" => "keyfleet",
          "key_id" => c.signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: c.secret
      )

    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{
          method: method,
          path: path,
          body: body,
          headers: %{"content-type" => "application/json"}
        },
        receipt,
        c.signer,
        secret: c.secret,
        audience: "keyfleet",
        wallet_audiences: ["keyfleet"]
      )

    Map.put(request, :method, method)
  end

  defp deliver(c, request) do
    Req.request!(
      method: request.method |> String.downcase() |> String.to_existing_atom(),
      url: c.app <> request.path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
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
end
