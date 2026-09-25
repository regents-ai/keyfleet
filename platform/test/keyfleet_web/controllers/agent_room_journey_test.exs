defmodule KeyfleetWeb.AgentRoomJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Rooms

  @join_path "/api/v1/agent/join/status"
  @pairing_path "/api/v1/agent/keys/fibonacci_syndicate/1/pairing"
  @rooms_path "/api/v1/agent/fleets/fibonacci_syndicate/rooms"
  @read_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/read"
  @send_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/send"
  @sync_path "/api/v1/agent/fleets/fibonacci_syndicate/sync"
  @key_read "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/read"
  @key_send "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/send"
  @read_proposal "/api/v1/agent/fleets/fibonacci_syndicate/proposals/read"
  @cascade "fibonacci_cascade"
  @create_cascade "/api/v1/agent/fleets/fibonacci_cascade/rooms/create"
  @join_body ~s({ "name": "Wallet agent", "declared_harness": "local" })
  @owner "0x" <> String.duplicate("a", 40)

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
    ChainHelpers.seed_cursor!("fibonacci_syndicate")
    Rooms.bootstrap_rooms!()

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
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, broker)
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "an agent reads every room before it may post in any of them", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    listed = send_signed(c, "GET", @rooms_path)
    assert listed.status == 200

    assert listed.body["rooms"] ==
             Enum.map(
               [
                 {"welcome", "Welcome and intros", "fixed"},
                 {"general", "General", "fixed"},
                 {"business", "Business", "fixed"},
                 {"voting", "Voting", "fixed"},
                 {"coding", "Coding", "fixed"}
               ] ++ Enum.map(1..5, &{"open-#{&1}", "Open room #{&1}", "open"}),
               fn {slug, name, kind} ->
                 %{
                   "slug" => slug,
                   "name" => name,
                   "kind" => kind,
                   "topic" => nil,
                   "topic_set_by" => nil,
                   "topic_set_at" => nil,
                   "head_seq" => 0
                 }
               end
             )

    assert Keyfleet.ContractSchema.errors(listed.body, "RoomList") == []

    assert send_signed(c, "POST", @read_general).body["messages"] == []

    refused = send_signed(c, "POST", @send_general, send_body("Standing by", "k-1"))
    assert refused.status == 403
    assert refused.body == %{"error" => "not_a_member"}

    unknown = send_signed(c, "POST", room_path("hull-survey", "read"))
    assert unknown.status == 404
    assert unknown.body == %{"error" => "room_unknown"}
  end

  test "a paired agent posts once however often it sends the same post", c do
    pair(c)

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
    assert conflict.body == %{"error" => "idempotency_conflict"}

    missing =
      send_signed(c, "POST", room_path("hull-survey", "send"), send_body("Anyone there?", "k-2"))

    assert missing.status == 404
    assert missing.body == %{"error" => "room_unknown"}

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
    assert answer.body == %{"error" => "reply_not_here"}

    assert Enum.map(send_signed(c, "POST", @read_general).body["messages"], & &1["seq"]) == [1]
  end

  test "an agent that is behind is given each post once and told where it now stands", c do
    pair(c)

    for n <- 1..3 do
      assert send_signed(c, "POST", @send_general, send_body("General #{n}", "g-#{n}")).status ==
               201
    end

    assert send_signed(c, "POST", room_path("coding", "send"), send_body("Coding 1", "w-1")).status ==
             201

    proposal = ProposalHelpers.proposal!("fibonacci_syndicate", 1)
    ProposalHelpers.vote!("fibonacci_syndicate", 1, @owner, true, [1])

    first = send_signed(c, "POST", @sync_path, sync_body(%{"general" => 0, "coding" => 0}))
    assert first.status == 200
    assert first.body["next_poll_seconds"] in 15..30

    assert %{
             "items" => [
               %{
                 "number" => 1,
                 "kind" => "decision",
                 "status" => "voting",
                 "yes_votes" => 1,
                 "no_votes" => 0,
                 "eligible_keys" => 7,
                 "text_preview" => "Proposal 1",
                 "changed_seq" => 2
               }
             ],
             "next_cursor" => 2,
             "head_seq" => 2,
             "has_more" => false
           } = first.body["proposals"]

    assert Keyfleet.ContractSchema.errors(first.body, "FleetSync") == []

    read = send_signed(c, "POST", @read_proposal, ~s({"number":1,"votes_after_seq":0}))
    assert read.status == 200
    assert read.body["proposal"]["text"] == "Proposal 1"
    assert read.body["proposal"]["text_sha256"] == proposal.text_sha256

    assert [%{"voter" => @owner, "support" => true, "votes" => 1, "keys" => [1], "seq" => 2}] =
             read.body["votes"]

    assert {read.body["votes_next_cursor"], read.body["votes_has_more"]} == {2, false}
    assert Keyfleet.ContractSchema.errors(read.body, "ProposalRead") == []

    missing = send_signed(c, "POST", @read_proposal, ~s({"number":2,"votes_after_seq":0}))
    assert {missing.status, missing.body} == {404, %{"error" => "proposal_unknown"}}

    assert first.body["graph"] == %{
             "run_id" => nil,
             "events" => [],
             "next_cursor" => 0,
             "has_more" => false,
             "watermark" => 0
           }

    assert Keyfleet.ContractSchema.errors(first.body["graph"], "WorkspaceChanges") == []

    assert [coding, general] = first.body["rooms"]
    assert %{"slug" => "general", "kind" => "fixed", "head_seq" => 3, "cursor" => 3} = general
    assert Enum.map(general["messages"], & &1["body"]) == ["General 1", "General 2", "General 3"]
    assert %{"slug" => "coding", "head_seq" => 1, "cursor" => 1} = coding

    second =
      send_signed(c, "POST", @sync_path, sync_body(%{"general" => 3, "coding" => 1}, 0, 2))

    assert Enum.map(second.body["rooms"], & &1["messages"]) == [[], []]
    assert %{"items" => [], "next_cursor" => 2, "has_more" => false} = second.body["proposals"]
    assert Enum.map(second.body["rooms"], & &1["cursor"]) == [1, 3]

    assert Enum.map(
             send_signed(c, "POST", @read_general, ~s({"after_seq": 2})).body["messages"],
             & &1["seq"]
           ) ==
             [3]

    assert Enum.map(
             send_signed(c, "POST", @read_general, ~s({"limit": 1})).body["messages"],
             & &1["seq"]
           ) ==
             [1]

    unknown = send_signed(c, "POST", @sync_path, sync_body(%{"hull-survey" => 0}))
    assert unknown.status == 404
    assert unknown.body == %{"error" => "room_unknown"}

    elsewhere = send_signed(c, "POST", "/api/v1/agent/fleets/hull_survey/sync", sync_body(%{}))
    assert {elsewhere.status, elsewhere.body} == {404, %{"error" => "fleet_unknown"}}
  end

  test "only the canonical signed room path and body reach the room actions", c do
    pair(c)

    for {method, path, body} <- [
          {"GET", @rooms_path, ~s({"after_seq":0})},
          {"GET", @rooms_path <> "?all=1", "{}"},
          {"POST", @read_general, ~s({"after_seq":"1"})},
          {"POST", @read_general, ~s({"page":1})},
          {"POST", @read_general <> "?after_seq=1", "{}"},
          {"POST", @send_general, ~s({"body":"Hello"})},
          {"POST", @send_general, ~s({"idempotency_key":"k-9"})},
          {"POST", @send_general,
           ~s({"body":"Hello","idempotency_key":"k-9","reply_to_id":"seven"})},
          {"POST", @send_general, ~s({"body":"Hello","idempotency_key":"k-9","slug":"coding"})},
          {"DELETE", @send_general, "{}"},
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
          {"POST", @read_proposal, ~s({"number":1,"votes_after_seq":0,"limit":5})},
          {"POST", "/api/v1/agent/fleets/Fibonacci_syndicate/rooms/general/messages/send", "{}"},
          {"POST", @read_general <> "/", "{}"}
        ] do
      assert send_signed(c, method, path, body).status == 401
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

  test "a place no room can reach, a schedule outside its range and a room named twice are refused as bad requests",
       c do
    pair(c)

    for {path, body} <- [
          {@read_general, ~s({"after_seq":#{2 ** 70}})},
          {@read_general, ~s({"after_seq":-1})},
          {@read_general, ~s({"limit":201})},
          {@sync_path, sync_body(%{"general" => 2 ** 70})},
          {@sync_path, sync_body(%{"general" => 0}, 2 ** 70)},
          {@sync_path, sync_body(%{"general" => 0}, 0, -1)},
          {@sync_path, sync_body(%{"general" => 0}, 0, 2 ** 70)},
          {@sync_path,
           sync_body(%{"general" => 0}, 0, 0, %{kind: "scheduled", every_minutes: 5})},
          {@sync_path,
           sync_body(%{"general" => 0}, 0, 0, %{kind: "scheduled", every_minutes: 1441})},
          {@read_proposal, ~s({"number":0,"votes_after_seq":0})},
          {@read_proposal, ~s({"number":#{2 ** 70},"votes_after_seq":0})},
          {@read_proposal, ~s({"number":1,"votes_after_seq":-1})}
        ] do
      refused = send_signed(c, "POST", path, body)
      assert {refused.status, refused.body} == {422, %{"error" => "out_of_range"}}
    end

    twice =
      Jason.encode!(%{
        rooms: [%{slug: "general", after_seq: 0}, %{slug: "general", after_seq: 0}],
        graph: %{after_seq: 0},
        proposals: %{after_seq: 0},
        run: %{kind: "session"}
      })

    refused = send_signed(c, "POST", @sync_path, twice)
    assert {refused.status, refused.body} == {422, %{"error" => "invalid_request"}}
  end

  test "an agent reads and writes a key's thread by the key's number", c do
    pair(c)
    sell!("fibonacci_syndicate", 2..5)

    empty = key_thread(c, 5, "read")

    assert {empty.status, empty.body} ==
             {200, %{"thread" => %{"token_id" => 5, "head_seq" => 0}, "messages" => []}}

    assert documented(empty, @key_read) == []

    {:ok, minted} = Keyfleet.Chain.minted("fibonacci_syndicate")
    unsold = minted + 1

    for {fleet, token_id, action, body, error} <- [
          {"fibonacci_syndicate", unsold, "read", "{}", "key_unknown"},
          {"fibonacci_syndicate", unsold, "send", send_body("Anyone there?", "k-0"),
           "key_unknown"},
          {"hull_survey", 1, "read", "{}", "fleet_unknown"},
          {"hull_survey", 1, "send", send_body("Anyone there?", "k-0"), "fleet_unknown"}
        ] do
      refused = key_thread(c, token_id, action, body, fleet)
      assert {refused.status, refused.body} == {404, %{"error" => error}}, "#{fleet} #{token_id}"
      assert documented(refused, if(action == "read", do: @key_read, else: @key_send)) == []
    end

    sent = key_thread(c, 5, "send", send_body("Welcome aboard", "k-1"))
    assert sent.status == 201
    assert documented(sent, @key_send) == []

    assert %{"seq" => 1, "as_key" => 1, "author_kind" => "agent", "body" => "Welcome aboard"} =
             sent.body["message"]

    assert sent.body["message"]["author_wallet"] == c.signer.address

    again = key_thread(c, 5, "send", send_body("Welcome aboard", "k-1"))
    assert {again.status, again.body} == {200, sent.body}
    assert documented(again, @key_send) == []

    conflict = key_thread(c, 5, "send", send_body("Welcome back", "k-1"))
    assert {conflict.status, conflict.body} == {422, %{"error" => "idempotency_conflict"}}
    assert documented(conflict, @key_send) == []

    in_room = send_signed(c, "POST", @send_general, send_body("Morning", "k-2"))

    answer =
      key_thread(
        c,
        5,
        "send",
        Jason.encode!(%{
          body: "On it",
          idempotency_key: "k-3",
          reply_to_id: in_room.body["message"]["id"]
        })
      )

    assert {answer.status, answer.body} == {422, %{"error" => "reply_not_here"}}

    read = key_thread(c, 5, "read")
    assert documented(read, @key_read) == []
    assert read.body["thread"] == %{"token_id" => 5, "head_seq" => 1}
    assert [%{"seq" => 1, "as_key" => 1, "body" => "Welcome aboard"}] = read.body["messages"]

    # A key's thread is never one of the fleet's rooms.
    listed = send_signed(c, "GET", @rooms_path)
    refute Enum.any?(listed.body["rooms"], &(&1["slug"] == "key-5" or &1["kind"] == "key"))

    for {path, body} <- [
          {room_path("key-5", "read"), "{}"},
          {room_path("key-5", "send"), send_body("Hello", "k-4")},
          {@sync_path, sync_body(%{"key-5" => 0})}
        ] do
      missing = send_signed(c, "POST", path, body)
      assert {missing.status, missing.body} == {404, %{"error" => "room_unknown"}}, path
    end

    created =
      send_signed(
        c,
        "POST",
        "/api/v1/agent/fleets/fibonacci_syndicate/rooms/create",
        ~s({"slug":"key-5","name":"Key 5"})
      )

    assert {created.status, created.body} == {422, %{"error" => "invalid_room"}}
  end

  test "only members write to a key's thread, and only while ownership is fresh", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    refused = key_thread(c, 1, "send", send_body("Standing by", "k-1"))
    assert {refused.status, refused.body} == {403, %{"error" => "not_a_member"}}
    assert documented(refused, @key_send) == []

    # Reading stays open to everyone.
    assert key_thread(c, 1, "read").status == 200

    pair(c)

    ChainHelpers.seed_cursor!("fibonacci_syndicate",
      observed_at: DateTime.add(DateTime.utc_now(), -3600)
    )

    refused = key_thread(c, 1, "send", send_body("Standing by", "k-1"))
    assert {refused.status, refused.body} == {503, %{"error" => "ownership_refreshing"}}
    assert documented(refused, @key_send) == []
  end

  test "only a key's path and a post's body reach a key's thread", c do
    pair(c)
    send_path = "/api/v1/agent/keys/fibonacci_syndicate/1/messages/send"
    read_path = "/api/v1/agent/keys/fibonacci_syndicate/1/messages/read"

    for {method, path, body} <- [
          {"POST", send_path, ~s({"body":"Hello","idempotency_key":"k-9","as_key":1})},
          {"POST", send_path, ~s({"body":"Hello","idempotency_key":"k-9","token_id":2})},
          {"POST", send_path, ~s({"body":"Hello","idempotency_key":"k-9","slug":"general"})},
          {"POST", send_path, ~s({"body":"Hello"})},
          {"POST", send_path, ~s({"body":"Hello","idempotency_key":"k-9","reply_to_id":"seven"})},
          {"POST", read_path, ~s({"page":1})},
          {"POST", read_path, ~s({"after_seq":"1"})},
          {"POST", read_path <> "?after_seq=1", "{}"},
          {"POST", read_path <> "/", "{}"},
          {"GET", read_path, "{}"},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/0/messages/read", "{}"},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/01/messages/read", "{}"},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/key-1/messages/read", "{}"},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/1234567890123456789/messages/read",
           "{}"},
          {"POST", "/api/v1/agent/keys/Fibonacci_syndicate/1/messages/send",
           send_body("Hello", "k-9")}
        ] do
      assert send_signed(c, method, path, body).status == 401, "#{method} #{path} #{body}"
    end

    for body <- [~s({"after_seq":#{2 ** 70}}), ~s({"after_seq":-1}), ~s({"limit":201})] do
      refused = send_signed(c, "POST", read_path, body)
      assert {refused.status, refused.body} == {422, %{"error" => "out_of_range"}}
      assert documented(refused, @key_read) == []
    end

    longest =
      ~s({"idempotency_key":"k-10","body":") <>
        String.duplicate("\\ud83d\\ude00", 4_000) <> ~s("})

    assert send_signed(c, "POST", send_path, longest).status == 201

    padded = longest <> String.duplicate(" ", 4_000 * 12 + 2 * 1024 - byte_size(longest) + 1)
    too_big = send_signed(c, "POST", send_path, padded)
    assert too_big.status == 413
    assert documented(too_big, @key_send) == []
  end

  describe "created and open rooms" do
    # Rooms other suites create outside the sandbox would count against the
    # Syndicate's limit, so these rooms are made on the Cascade fleet.
    setup do
      ChainHelpers.seed_cursor!(@cascade)
      sell!(@cascade, 1..4)
      :ok
    end

    test "an agent creates a room every member posts in", c do
      pair(c, @cascade, 3)

      created = create_room(c, %{slug: "hull-survey", name: "Hull survey"})

      assert {created.status, created.body} ==
               {201,
                %{
                  "room" => %{
                    "slug" => "hull-survey",
                    "name" => "Hull survey",
                    "kind" => "created",
                    "topic" => nil,
                    "topic_set_by" => nil,
                    "topic_set_at" => nil,
                    "head_seq" => 0
                  }
                }}

      assert Keyfleet.ContractSchema.errors(created.body["room"], "Room") == []

      for {body, status, error} <- [
            {%{slug: "hull-survey", name: "Again"}, 409, "room_taken"},
            {%{slug: "general", name: "Mine"}, 422, "invalid_room"},
            {%{slug: "welcome", name: "Mine"}, 422, "invalid_room"},
            {%{slug: "open-1", name: "Mine"}, 422, "invalid_room"},
            {%{slug: "Hull", name: "Hull"}, 422, "invalid_room"},
            {%{slug: "hull", name: ""}, 422, "invalid_room"},
            {%{slug: "hull", name: "Hull\u200B"}, 422, "invalid_room"},
            {%{slug: "hull", name: "Hull\u2028survey"}, 422, "invalid_room"},
            {%{slug: "hull", name: " coding "}, 409, "name_taken"},
            {%{slug: "hull", name: "Ｃｏｄｉｎｇ"}, 409, "name_taken"},
            {%{slug: "hull", name: "Welcome and Intros"}, 409, "name_taken"},
            {%{slug: "hull", name: "Open room 2"}, 409, "name_taken"},
            {%{slug: "hull", name: "HULL survey"}, 409, "name_taken"}
          ] do
        refused = create_room(c, body)
        assert {refused.status, refused.body} == {status, %{"error" => error}}, inspect(body)
      end

      elsewhere =
        send_signed(
          c,
          "POST",
          "/api/v1/agent/fleets/hull_survey/rooms/create",
          ~s({"slug":"hull","name":"Hull"})
        )

      assert {elsewhere.status, elsewhere.body} == {404, %{"error" => "fleet_unknown"}}

      sent = send_signed(c, "POST", cascade_room("hull-survey", "send"), send_body("Hi", "k-1"))
      assert sent.status == 201

      # A person holding one of the fleet's keys posts there as well.
      Rooms.send_message!(
        %{fleet_id: @cascade, slug: "hull-survey", body: "Hello", idempotency_key: "h-1"},
        actor: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
      )

      listed = send_signed(c, "GET", "/api/v1/agent/fleets/#{@cascade}/rooms")

      assert Enum.map(listed.body["rooms"], &{&1["slug"], &1["kind"]}) ==
               Enum.map(~w(welcome general business voting coding), &{&1, "fixed"}) ++
                 Enum.map(1..5, &{"open-#{&1}", "open"}) ++ [{"hull-survey", "created"}]

      synced =
        send_signed(
          c,
          "POST",
          "/api/v1/agent/fleets/#{@cascade}/sync",
          sync_body(%{"hull-survey" => 0, "open-1" => 0})
        )

      assert Enum.map(synced.body["rooms"], &{&1["slug"], &1["kind"], &1["head_seq"]}) ==
               [{"hull-survey", "created", 2}, {"open-1", "open", 0}]
    end

    test "an agent names an open room, and the room says who named it", c do
      pair(c, @cascade, 3)

      named = name_room(c, "open-2", "Hull survey")
      assert named.status == 200
      assert Keyfleet.ContractSchema.errors(named.body["room"], "Room") == []

      assert %{
               "slug" => "open-2",
               "kind" => "open",
               "topic" => "Hull survey",
               "topic_set_by" => signer,
               "topic_set_at" => set_at,
               "head_seq" => 1
             } = named.body["room"]

      assert signer == c.signer.address
      assert {:ok, _at, 0} = DateTime.from_iso8601(set_at)

      read = send_signed(c, "POST", cascade_room("open-2", "read"))
      assert Keyfleet.ContractSchema.errors(read.body, "RoomMessages") == []

      assert [%{"kind" => "room_named", "body" => "Hull survey", "author_wallet" => ^signer}] =
               read.body["messages"]

      assert read.body["room"]["topic"] == "Hull survey"

      # Naming it the same again changes nothing; a new name adds a line.
      again = name_room(c, "open-2", "Hull survey")
      assert {again.status, again.body["room"]["head_seq"]} == {200, 1}
      assert again.body["room"]["topic_set_at"] == set_at

      # A room is renamed at most once a minute.
      too_soon = name_room(c, "open-2", "Dry dock")
      assert {too_soon.status, too_soon.body} == {429, %{"error" => "rename_too_soon"}}
      assert [wait] = Req.Response.get_header(too_soon, "retry-after")
      assert String.to_integer(wait) in 59..60

      a_minute_passes("open-2")
      renamed = name_room(c, "open-2", "Dry dock")
      assert {renamed.body["room"]["topic"], renamed.body["room"]["head_seq"]} == {"Dry dock", 2}

      for {slug, topic, status, error} <- [
            {"general", "Mine", 422, "room_not_open"},
            {"open-9", "Mine", 404, "room_unknown"},
            {"open-3", "", 422, "invalid_topic"},
            {"open-3", "   ", 422, "invalid_topic"},
            {"open-3", String.duplicate("h", 81), 422, "invalid_topic"},
            {"open-3", "Hull\nsurvey", 422, "invalid_topic"},
            {"open-3", "Hull\u200Bsurvey", 422, "invalid_topic"},
            {"open-3", "Hull\u2028survey", 422, "invalid_topic"},
            {"open-3", "Hull \u202Esurvey", 422, "invalid_topic"},
            {"open-3", "General", 409, "name_taken"},
            {"open-3", "Ｇｅｎｅｒａｌ", 409, "name_taken"},
            {"open-3", "DRY DOCK", 409, "name_taken"}
          ] do
        refused = name_room(c, slug, topic)
        assert {refused.status, refused.body} == {status, %{"error" => error}}, inspect(topic)
      end

      create_room(c, %{slug: "hull", name: "Hull"})
      refused = name_room(c, "hull", "Mine")
      assert {refused.status, refused.body} == {422, %{"error" => "room_not_open"}}

      elsewhere =
        send_signed(
          c,
          "POST",
          "/api/v1/agent/fleets/hull_survey/rooms/open-1/topic",
          ~s({"topic":"Hull"})
        )

      assert {elsewhere.status, elsewhere.body} == {404, %{"error" => "fleet_unknown"}}
    end

    test "while key ownership is not fresh, an agent neither posts, creates nor names a room",
         c do
      pair(c, @cascade, 3)
      ChainHelpers.seed_cursor!(@cascade, observed_at: DateTime.add(DateTime.utc_now(), -3600))

      for {path, body} <- [
            {@create_cascade, ~s({"slug":"hull","name":"Hull"})},
            {cascade_topic("open-1"), ~s({"topic":"Hull"})},
            {cascade_room("general", "send"), send_body("Standing by", "k-2")}
          ] do
        refused = send_signed(c, "POST", path, body)
        assert {refused.status, refused.body} == {503, %{"error" => "ownership_refreshing"}}
      end

      # Reading stays open to everyone.
      assert send_signed(c, "POST", cascade_room("open-1", "read")).status == 200
    end

    test "a room the database refuses for a reason of its own is answered, not a crash", c do
      pair(c, @cascade, 3)

      Keyfleet.Repo.query!(
        "ALTER TABLE keyfleet_app.rooms ADD CONSTRAINT refuse_hull CHECK (slug <> 'hull') NOT VALID"
      )

      refused = create_room(c, %{slug: "hull", name: "Hull"})
      assert {refused.status, refused.body} == {422, %{"error" => "invalid_room"}}
      assert create_room(c, %{slug: "keel", name: "Keel"}).status == 201
    end

    test "an agent running no key creates no room and names none", c do
      assert send_signed(c, "POST", @join_path, @join_body).status == 200

      refused = create_room(c, %{slug: "hull", name: "Hull"})
      assert {refused.status, refused.body} == {403, %{"error" => "not_a_member"}}

      refused = name_room(c, "open-1", "Hull")
      assert {refused.status, refused.body} == {403, %{"error" => "not_a_member"}}
    end

    # Five fixed rooms, five open rooms and a hundred created ones: 110 rooms.
    test "a full fleet creates no more rooms, and one catch-up reads all of its rooms", c do
      pair(c, @cascade, 3)

      # Who may create a room is shown above; these only fill the fleet.
      for n <- 1..100 do
        Rooms.create_room!(%{fleet_id: @cascade, slug: "made-#{n}", name: "Made #{n}"},
          authorize?: false
        )
      end

      refused = create_room(c, %{slug: "made-101", name: "Made 101"})
      assert {refused.status, refused.body} == {409, %{"error" => "room_limit_reached"}}

      every_room = Map.new(Rooms.list_rooms!(@cascade), &{&1.slug, 0})
      assert map_size(every_room) == 110

      synced =
        send_signed(c, "POST", "/api/v1/agent/fleets/#{@cascade}/sync", sync_body(every_room))

      assert synced.status == 200
      assert length(synced.body["rooms"]) == 110

      one_more = Map.put(every_room, "made-101", 0)

      refused =
        send_signed(c, "POST", "/api/v1/agent/fleets/#{@cascade}/sync", sync_body(one_more))

      assert {refused.status, refused.body} == {422, %{"error" => "out_of_range"}}

      member = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
      cursors = Enum.map(one_more, fn {slug, seq} -> %{slug: slug, after_seq: seq} end)
      assert Rooms.sync(@cascade, cursors, 0, 0, member) == {:error, :invalid_request}
    end

    test "only a slug and a name reach creating a room, and only a topic reaches naming one", c do
      pair(c, @cascade, 3)
      topic = cascade_topic("open-1")

      for {method, path, body} <- [
            {"POST", @create_cascade, ~s({"slug":"hull"})},
            {"POST", @create_cascade, ~s({"name":"Hull"})},
            {"POST", @create_cascade, ~s({"slug":7,"name":"Hull"})},
            {"POST", @create_cascade, ~s({"slug":"hull","name":["Hull"]})},
            {"POST", @create_cascade, ~s({"slug":"hull","name":"Hull","kind":"open"})},
            {"POST", @create_cascade, ~s({"slug":"hull","name":"Hull","topic":"Hull"})},
            {"POST", @create_cascade,
             ~s({"slug":"hull","name":"Hull","fleet_id":"fleet_tech_classic"})},
            {"POST", @create_cascade <> "?kind=open", ~s({"slug":"hull","name":"Hull"})},
            {"POST", @create_cascade <> "/", ~s({"slug":"hull","name":"Hull"})},
            {"GET", @create_cascade, ~s({"slug":"hull","name":"Hull"})},
            {"POST", "/api/v1/agent/fleets/Fibonacci_cascade/rooms/create",
             ~s({"slug":"hull","name":"Hull"})},
            {"POST", topic, "{}"},
            {"POST", topic, ~s({"topic":7})},
            {"POST", topic, ~s({"topic":null})},
            {"POST", topic, ~s({"topic":["Hull"]})},
            {"POST", topic, ~s({"topic":"Hull","slug":"open-2"})},
            {"POST", topic, ~s({"topic":"Hull","topic_set_by":"0x00"})},
            {"POST", topic <> "?topic=Hull", ~s({"topic":"Hull"})},
            {"POST", topic <> "/", ~s({"topic":"Hull"})},
            {"GET", topic, ~s({"topic":"Hull"})},
            {"POST", cascade_topic("Open-1"), ~s({"topic":"Hull"})}
          ] do
        assert send_signed(c, method, path, body).status == 401, "#{method} #{path} #{body}"
      end

      assert create_room(c, %{slug: "hull", name: "Hull"}).status == 201

      # The created room's name is taken, whatever its case.
      taken = name_room(c, "open-1", "hULL")
      assert {taken.status, taken.body} == {409, %{"error" => "name_taken"}}
      assert name_room(c, "open-1", "Hull works").status == 200
    end
  end

  # Moves the room's last naming back a minute, so it may be renamed.
  defp a_minute_passes(slug) do
    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic_set_at = topic_set_at - interval '61 seconds' " <>
        "WHERE fleet_id = $1 AND slug = $2",
      [@cascade, slug]
    )
  end

  defp create_room(c, body), do: send_signed(c, "POST", @create_cascade, Jason.encode!(body))

  defp name_room(c, slug, topic),
    do: send_signed(c, "POST", cascade_topic(slug), Jason.encode!(%{topic: topic}))

  defp cascade_topic(slug), do: "/api/v1/agent/fleets/#{@cascade}/rooms/#{slug}/topic"

  defp cascade_room(slug, action),
    do: "/api/v1/agent/fleets/#{@cascade}/rooms/#{slug}/messages/#{action}"

  defp sell!(fleet, token_ids) do
    for token_id <- token_ids do
      Keys.record_epoch!(
        %{
          fleet_id: fleet,
          token_id: token_id,
          ownership_epoch: 1,
          owner_wallet: @owner,
          block_number: 10,
          block_hash: "0x" <> String.duplicate("a", 64),
          transaction_hash:
            "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}"), case: :lower),
          log_index: 0
        },
        actor: %Actors.System{}
      )
    end
  end

  defp pair(c, fleet, token_id) do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    assert send_signed(c, "POST", "/api/v1/agent/keys/#{fleet}/#{token_id}/pairing").status == 200

    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    [request] = Keys.list_pairing_requests!(fleet, token_id, actor: owner)
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
  end

  defp pair(c) do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    assert send_signed(c, "POST", @pairing_path).status == 200

    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    [request] = Keys.list_pairing_requests!("fibonacci_syndicate", 1, actor: owner)
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
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

  defp send_signed(c, method, path, body \\ "{}"),
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
