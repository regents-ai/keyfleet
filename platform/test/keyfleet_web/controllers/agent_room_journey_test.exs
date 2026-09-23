defmodule KeyFleetWeb.AgentRoomJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Rooms

  @join_path "/api/v1/agent/join/status"
  @pairing_path "/api/v1/agent/keys/fibonacci_syndicate/1/pairing"
  @rooms_path "/api/v1/agent/fleets/fibonacci_syndicate/rooms"
  @read_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/read"
  @send_general "/api/v1/agent/fleets/fibonacci_syndicate/rooms/general/messages/send"
  @sync_path "/api/v1/agent/fleets/fibonacci_syndicate/sync"
  @join_body ~s({ "name": "Wallet agent", "declared_harness": "local" })
  @owner "0x" <> String.duplicate("a", 40)

  setup do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(KeyFleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!("fibonacci_syndicate")
    Rooms.bootstrap_core_rooms!()

    Keys.record_epoch!(
      %{
        fleet_id: "fibonacci_syndicate",
        token_id: 1,
        ownership_epoch: 0,
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
    app = server(:product, &KeyFleetWeb.Endpoint.call(&1, KeyFleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "an agent reads every room before it may post in any of them", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    listed = send_signed(c, "GET", @rooms_path)
    assert listed.status == 200

    assert listed.body["rooms"] == [
             %{"slug" => "general", "name" => "General", "head_seq" => 0},
             %{"slug" => "planning", "name" => "Planning", "head_seq" => 0},
             %{"slug" => "work", "name" => "Work", "head_seq" => 0}
           ]

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
      send_signed(c, "POST", room_path("work", "send"), send_body("Hull survey log", "k-3"))

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

    assert send_signed(c, "POST", room_path("work", "send"), send_body("Work 1", "w-1")).status ==
             201

    first = send_signed(c, "POST", @sync_path, sync_body(%{"general" => 0, "work" => 0}))
    assert first.status == 200
    assert first.body["proposals"] == []
    assert first.body["next_poll_seconds"] in 15..30

    assert first.body["graph"] == %{
             "run_id" => nil,
             "events" => [],
             "next_cursor" => 0,
             "has_more" => false,
             "watermark" => 0
           }

    assert KeyFleet.ContractSchema.errors(first.body["graph"], "WorkspaceChanges") == []

    assert [general, work] = first.body["rooms"]
    assert %{"slug" => "general", "head_seq" => 3, "cursor" => 3} = general
    assert Enum.map(general["messages"], & &1["body"]) == ["General 1", "General 2", "General 3"]
    assert %{"slug" => "work", "head_seq" => 1, "cursor" => 1} = work

    second = send_signed(c, "POST", @sync_path, sync_body(%{"general" => 3, "work" => 1}))
    assert Enum.map(second.body["rooms"], & &1["messages"]) == [[], []]
    assert Enum.map(second.body["rooms"], & &1["cursor"]) == [3, 1]

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
          {"POST", @send_general, ~s({"body":"Hello","idempotency_key":"k-9","slug":"work"})},
          {"DELETE", @send_general, "{}"},
          {"POST", @sync_path, "{}"},
          {"POST", @sync_path, ~s({"rooms":[{"slug":"general"}]})},
          {"POST", @sync_path,
           ~s({"rooms":[{"slug":"general","after_seq":0}],"graph":{"after_seq":0},"all":true})},
          {"POST", @sync_path,
           ~s({"rooms":[{"slug":"general","after_seq":0}],"graph":{"after_seq":0,"all":true}})},
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

  test "a place no room can reach and a room named twice are refused as bad requests", c do
    pair(c)

    for {path, body} <- [
          {@read_general, ~s({"after_seq":#{2 ** 70}})},
          {@read_general, ~s({"after_seq":-1})},
          {@read_general, ~s({"limit":201})},
          {@sync_path, sync_body(%{"general" => 2 ** 70})},
          {@sync_path, sync_body(%{"general" => 0}, 2 ** 70)}
        ] do
      refused = send_signed(c, "POST", path, body)
      assert {refused.status, refused.body} == {422, %{"error" => "out_of_range"}}
    end

    twice =
      Jason.encode!(%{
        rooms: [%{slug: "general", after_seq: 0}, %{slug: "general", after_seq: 0}],
        graph: %{after_seq: 0}
      })

    refused = send_signed(c, "POST", @sync_path, twice)
    assert {refused.status, refused.body} == {422, %{"error" => "invalid_request"}}
  end

  defp pair(c) do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    assert send_signed(c, "POST", @pairing_path).status == 200

    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    [request] = Keys.list_pairing_requests!("fibonacci_syndicate", 1, actor: owner)
    Keys.approve_pairing!(request, %{}, actor: owner)
  end

  defp room_path(slug, action),
    do: "/api/v1/agent/fleets/fibonacci_syndicate/rooms/#{slug}/messages/#{action}"

  defp send_body(body, key), do: Jason.encode!(%{body: body, idempotency_key: key})

  defp sync_body(cursors, graph_after_seq \\ 0),
    do:
      Jason.encode!(%{
        rooms: Enum.map(cursors, fn {slug, seq} -> %{slug: slug, after_seq: seq} end),
        graph: %{after_seq: graph_after_seq}
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
