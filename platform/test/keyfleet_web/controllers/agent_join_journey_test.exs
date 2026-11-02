defmodule KeyfleetWeb.AgentJoinJourneyTest do
  use ExUnit.Case, async: false
  import KeyfleetWeb.RefusalHelpers
  import Plug.Conn
  alias KeyfleetWeb.SignedAgentHelpers
  @path "/api/v1/agent/join/status"
  @update_path "/api/v1/agent/profile/update"
  @credits_history_path "/api/v1/agent/account/credits/history"
  @body ~s({ "name": "Wallet agent", "declared_harness": "local" })

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    {:ok, signer} = Siwa.LocalSigner.new()
    Keyfleet.PairingHelpers.pair_wallet!(signer.address)
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "only the exact signed wallet request creates or resumes its unchanged profile", c do
    signed = signed(c, @body)
    changed = String.replace(@body, "Wallet agent", "Changed agent")
    # The sign-in server's refusal reaches the agent in its own words.
    tampered = send_request(c, %{signed | body: changed})
    assert tampered.status == 401
    assert tampered.body == %{"error" => SignedAgentHelpers.refusal()}
    first = send_request(c, signed)
    assert first.status == 200

    assert %{"registry_listing" => nil, "human_backed" => false, "same_person_agent_count" => nil} =
             first.body

    profile = first.body["profile"]
    assert profile["wallet_address"] == c.signer.address
    assert profile["name"] == "Wallet agent"
    assert send_request(c, signed).status == 401
    resumed = send_request(c, signed(c, changed))
    assert resumed.status == 200
    assert resumed.body["profile"] == profile
    changed_digest = digest(changed)
    body_digest = digest(@body)
    assert_receive {:broker_payload, %{"body_digest" => ^changed_digest}}

    assert_receive {:broker_payload,
                    %{
                      "body_digest" => ^body_digest,
                      "method" => "POST",
                      "path" => @path,
                      "headers" => headers
                    }}

    refute Map.has_key?(headers, "cookie")
    refute Map.has_key?(headers, "authorization")

    invalid = send_request(c, signed(c, ~s({"name":"","declared_harness":"local"})))
    assert invalid.status == 422
    assert invalid.body == refused("invalid_profile")
  end

  test "foreign receipt audience and chain never acquire a Keyfleet actor", c do
    assert send_request(c, signed(c, @body, "patchbay")).status == 401
    request = signed(c, @body)

    assert send_request(c, %{request | headers: Map.put(request.headers, "x-agent-chain-id", "1")}).status ==
             401
  end

  test "update takes only editable fields, and refuses a request's shape before verification",
       c do
    request = signed(c, "{}", "keyfleet", 8453, @update_path)

    oversized = %{request | body: String.duplicate(" ", 24 * 1024 + 1)}
    assert send_request(c, oversized).status == 413

    valid = signed(c, ~s({"name":"Updated"}), "keyfleet", 8453, @update_path)

    for {method, path, status} <- [
          {:get, @update_path, 405},
          {:post, @update_path <> "?id=forged", 401},
          {:post, "/api/v1/agent/profile/%75pdate", 404}
        ] do
      assert Req.request!(
               method: method,
               url: c.app <> path,
               headers: valid.headers,
               body: valid.body,
               retry: false,
               redirect: false
             ).status == status
    end

    refute_receive {:broker_payload, _}

    # Once its signature verifies, a body naming nothing editable is told the
    # fields an update takes.
    for body <- [
          "{}",
          "[]",
          ~s({"id":"forged"}),
          ~s({"wallet_address":"forged"}),
          ~s({"last_activity_at":"forged"}),
          ~s({"status_updated_at":"forged"}),
          ~s({"unknown":"forged"})
        ] do
      refused = send_request(c, signed(c, body, "keyfleet", 8453, @update_path))
      body_digest = digest(body)
      assert_receive {:broker_payload, %{"body_digest" => ^body_digest}}
      assert misfit?(refused), body

      assert refused.body["error"]["hint"] =~
               "naming at least one of: name, declared_harness, proficiencies"
    end

    assert send_request(c, signed(c, @body)).status == 200
    assert_receive {:broker_payload, _}
    raw = Jason.encode!(%{proficiencies: List.duplicate(String.duplicate("\\", 2000), 6)})
    padded = raw <> String.duplicate(" ", 24 * 1024 - byte_size(raw))
    at_limit = signed(c, padded, "keyfleet", 8453, @update_path)
    assert send_request(c, at_limit).status == 200
    padded_digest = digest(padded)
    assert_receive {:broker_payload, %{"body_digest" => ^padded_digest}}
    assert send_request(c, %{at_limit | body: padded <> " "}).status == 413
    refute_receive {:broker_payload, _}
  end

  test "chunked bytes remain signed and oversized streams never reach verification", c do
    request = signed(c, @body)

    response =
      Req.post!(c.app <> @path,
        headers: request.headers,
        body: Stream.map(String.codepoints(@body), & &1),
        retry: false,
        redirect: false
      )

    assert response.status == 200
    body_digest = digest(@body)
    assert_receive {:broker_payload, %{"body_digest" => ^body_digest}}

    oversized =
      Req.post!(c.app <> @path,
        headers: request.headers,
        body: Stream.repeatedly(fn -> String.duplicate("x", 1024) end) |> Stream.take(5),
        retry: false,
        redirect: false
      )

    assert oversized.status == 413
    refute_receive {:broker_payload, _}
  end

  test "a signed body to the credits history is read as it was signed", c do
    response = send_request(c, signed(c, "{}", "keyfleet", 8453, @credits_history_path))

    assert response.status == 200
    body_digest = digest("{}")

    assert_receive {:broker_payload,
                    %{"body_digest" => ^body_digest, "path" => @credits_history_path}}
  end

  test "a credits history body changed after signing is refused", c do
    request = signed(c, "{}", "keyfleet", 8453, @credits_history_path)
    response = send_request(c, %{request | body: ~s({"after":"x"})})

    assert response.status == 401
    assert response.body == %{"error" => SignedAgentHelpers.refusal()}
  end

  test "verification transport never retries or follows redirects", c do
    test = self()

    target =
      server(:redirect_target, fn conn, _ ->
        send(test, :redirect_followed)
        send_resp(conn, 500, "unreachable")
      end)

    redirect =
      server(:redirect, fn conn, _ ->
        send(test, :redirect_called)
        conn |> put_resp_header("location", target) |> send_resp(307, "")
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, redirect)
    redirected = send_request(c, signed(c, @body))
    assert redirected.status == 503
    assert redirected.body["error"]["code"] == "siwa_request_failed"
    assert_receive :redirect_called
    refute_receive :redirect_followed

    failure =
      server(:unavailable, fn conn, _ ->
        send(test, :unavailable_called)
        send_resp(conn, 503, "private diagnostics")
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, failure)
    response = send_request(c, signed(c, @body))
    assert response.status == 503

    assert response.body == %{
             "error" => %{
               "code" => "sign_in_refused",
               "message" => "The request's wallet signature was not accepted.",
               "hint" => "Sign the request again with your agent key, then send it."
             }
           }

    assert_receive :unavailable_called
    refute_receive :unavailable_called
    stop_supervised!(:unavailable)
    assert send_request(c, signed(c, @body)).status == 503
  end

  test "the request boundary rejects ambiguity before it spends broker replay state", c do
    signed = signed(c, @body)

    assert send_request(c, %{signed | body: String.duplicate(" ", 4097)}).status == 413

    for header <- Siwa.Contract.forwarded_headers() do
      duplicate = Plug.Test.conn("POST", @path, @body)

      duplicate = %{
        duplicate
        | req_headers: [
            {String.upcase(header), signed.headers[header]} | Map.to_list(signed.headers)
          ]
      }

      refusal = KeyfleetWeb.Endpoint.call(duplicate, [])
      assert refusal.status == 401
      assert Jason.decode!(refusal.resp_body) == refused("duplicate_proof")
    end

    # A wrong method or address is told so, never that the sign-in failed.
    for {method, path, status} <- [
          {:get, @path, 405},
          {:put, @path, 405},
          {:post, @path <> "?name=x", 401},
          {:post, "/api/v1/agent/other", 404},
          {:post, "/api/v1/%61gent/join/status", 404}
        ] do
      assert Req.request!(
               method: method,
               url: c.app <> path,
               headers: signed.headers,
               body: @body,
               retry: false,
               redirect: false
             ).status == status
    end

    queried =
      Req.request!(
        method: :post,
        url: c.app <> @path <> "?name=x",
        headers: signed.headers,
        body: @body,
        retry: false,
        redirect: false
      )

    assert {queried.status, queried.body} == {401, refused("unsupported_query")}

    assert send_request(c, %{
             signed
             | headers: Map.put(signed.headers, "content-type", "text/plain")
           }).status == 415

    refute_receive {:broker_payload, _}
    assert send_request(c, signed).status == 200
  end

  # Costly failure: a header the signature does not cover changes who the
  # agent is or what it may do.
  test "an unsigned header such as x-agent-role: admin is accepted and grants nothing", c do
    assert send_request(c, signed(c, @body)).status == 200
    plain = send_request(c, signed(c, @body))
    assert plain.status == 200

    for {header, value} <- [
          {"x-agent-role", "admin"},
          {"x-agent-token-id", "1"},
          {"x-agent-id", "untrusted"},
          {"x-agent-registry-address", "untrusted"},
          {"x-siwa-audience", "untrusted"}
        ] do
      request = signed(c, @body)
      extra = send_request(c, %{request | headers: Map.put(request.headers, header, value)})
      assert {extra.status, extra.body} == {plain.status, plain.body}, header
    end

    # The sign-in server hears the signed headers and nothing else.
    for _sent <- 1..7 do
      assert_receive {:broker_payload, %{"headers" => forwarded}}
      assert Enum.sort(Map.keys(forwarded)) == Enum.sort(Siwa.Contract.forwarded_headers())
    end

    refute_receive {:broker_payload, _}
  end

  test "a body is judged only once its signature verifies", c do
    # A body other than the one signed fails sign-in, whatever its shape.
    tampered = %{signed(c, @body) | body: ~s({"name":"a","declared_harness":"b","wallet":"x"})}
    assert send_request(c, tampered).status == 401

    for body <- [
          "{}",
          "[1]",
          "not json",
          ~s({"name":"a","declared_harness":"b","wallet":"x"}),
          ~s({"name":1,"declared_harness":"b"})
        ] do
      refused = send_request(c, signed(c, body))
      assert misfit?(refused), body

      assert refused.body["error"]["hint"] ==
               "This operation takes a JSON object with exactly these fields: name, declared_harness. Check each field's kind and range against the docs, then send it again."
    end
  end

  test "malformed broker principals cannot become product actors", c do
    wallet = c.signer.address

    good = %{
      "verified" => true,
      "walletAddress" => wallet,
      "chainId" => 8453,
      "verificationMethod" => "eoa_recovery",
      "keyId" => wallet,
      "receiptExpiresAt" => DateTime.to_iso8601(DateTime.utc_now()),
      "requiredHeaders" => [],
      "requiredCoveredComponents" => [],
      "coveredComponents" => [],
      "agentRegistration" => nil,
      "agentBook" => nil,
      "principal" => %{
        "kind" => "wallet",
        "wallet_address" => wallet,
        "chain_id" => 8453,
        "audience" => "keyfleet"
      }
    }

    signed_in = fn chain_id, method ->
      good
      |> Map.merge(%{"chainId" => chain_id, "verificationMethod" => method})
      |> put_in(["principal", "chain_id"], chain_id)
    end

    conn =
      Plug.Test.conn("POST", @path)
      |> Plug.Conn.assign(:raw_body, @body)
      |> Plug.Conn.put_req_header("x-siwa-receipt", "receipt")
      |> Plug.Conn.put_req_header("x-key-id", wallet)

    # A plain wallet proves its key on either chain. A smart wallet is only
    # proven on the chain it was checked on, and keys are held on Base.
    for {chain_id, method} <- [
          {8453, "eoa_recovery"},
          {1, "eoa_recovery"},
          {8453, "erc1271"},
          {8453, "erc6492"}
        ] do
      assert {:ok, %{assigns: %{agent_actor: actor}}} =
               KeyfleetWeb.Plugs.SignedAgent.accept(conn, signed_in.(chain_id, method), nil)

      assert {actor.chain_id, actor.verification_method} ==
               {chain_id, String.to_existing_atom(method)}
    end

    # Each verified request saves the agent's registry listing and the World
    # ID person behind it onto its profile. The first person stays for good
    # (Sean, 7 Oct): a request naming nobody, or someone else, leaves them,
    # and one naming them again updates their count. What the sign-in server
    # says beyond the fields Keyfleet uses is its own.
    human_id = "0x" <> String.duplicate("1", 64)

    listed =
      Map.merge(good, %{
        "agentRegistration" => %{
          "agentId" => "eip155:8453:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432:97609",
          "tokenId" => "97609",
          "profileUrl" => "https://siwa.regents.sh/agents/registrations/1",
          "registryUrl" => "https://www.8004scan.io/agents/base/97609"
        },
        "agentBook" => %{"humanId" => human_id, "agentCount" => 2},
        "somethingNew" => true
      })

    {:ok, %{assigns: %{agent_actor: plain}}} =
      KeyfleetWeb.Plugs.SignedAgent.accept(conn, good, nil)

    Keyfleet.Agents.ensure_profile!(%{name: "Wallet agent", declared_harness: "Hermes Agent"},
      actor: plain
    )

    assert {:ok, %{assigns: %{agent_actor: %{wallet_address: ^wallet} = actor}}} =
             KeyfleetWeb.Plugs.SignedAgent.accept(conn, listed, nil)

    refute inspect(actor) =~ human_id

    assert %{
             registry_url: "https://www.8004scan.io/agents/base/97609",
             human_id: ^human_id,
             same_person_agent_count: 2
           } = Keyfleet.Agents.get_my_profile!(actor: actor)

    assert {:ok, _conn} = KeyfleetWeb.Plugs.SignedAgent.accept(conn, good, nil)

    assert %{registry_url: nil, human_id: ^human_id, same_person_agent_count: 2} =
             Keyfleet.Agents.get_my_profile!(actor: actor)

    someone_else = %{"humanId" => "0x" <> String.duplicate("2", 64), "agentCount" => 5}

    assert {:ok, _conn} =
             KeyfleetWeb.Plugs.SignedAgent.accept(
               conn,
               Map.put(good, "agentBook", someone_else),
               nil
             )

    assert %{human_id: ^human_id, same_person_agent_count: 2} =
             Keyfleet.Agents.get_my_profile!(actor: actor)

    assert {:ok, _conn} =
             KeyfleetWeb.Plugs.SignedAgent.accept(
               conn,
               Map.put(good, "agentBook", %{"humanId" => human_id, "agentCount" => 3}),
               nil
             )

    assert %{human_id: ^human_id, same_person_agent_count: 3} =
             Keyfleet.Agents.get_my_profile!(actor: actor)

    invalid =
      [
        Map.put(good, "verified", false),
        Map.put(good, "walletAddress", String.upcase(wallet)),
        Map.put(good, "chainId", 1),
        Map.delete(good, "verificationMethod"),
        Map.put(good, "verificationMethod", "passkey"),
        signed_in.(10, "eoa_recovery"),
        Map.put(good, "principal", nil)
      ] ++
        Enum.map(
          [
            {"kind", "agent"},
            {"wallet_address", "0x" <> String.duplicate("0", 40)},
            {"chain_id", 1},
            {"audience", "patchbay"}
          ],
          fn {key, value} -> put_in(good, ["principal", key], value) end
        )

    for data <- invalid do
      assert {:error, _} = KeyfleetWeb.Plugs.SignedAgent.accept(conn, data, nil)
    end

    # Signing in again on Ethereum can't help a smart wallet, so it is told
    # to use Base rather than to sign in again.
    for method <- ["erc1271", "erc6492"] do
      assert {:error, %{reason: :smart_wallet_on_ethereum} = refusal} =
               KeyfleetWeb.Plugs.SignedAgent.accept(conn, signed_in.(1, method), nil)

      reply = KeyfleetWeb.Plugs.SignedAgent.deny(conn, refusal)

      assert {reply.status, Jason.decode!(reply.resp_body)} ==
               {401, refused("smart_wallet_on_ethereum")}
    end
  end

  test "missing or invalid broker origins fail closed without exposing configuration", c do
    for origin <- [
          nil,
          "",
          "http://example.com",
          "https://user:password@example.com",
          "https://example.com/path",
          "https://example.com?x=1",
          "https://example.com#fragment",
          "https://example.com:0"
        ] do
      Application.put_env(:keyfleet, :siwa_broker_url, origin)
      response = send_request(c, signed(c, @body))
      assert response.status == 503
      assert response.body == refused("siwa_request_failed")
    end
  end

  defp signed(c, body, audience \\ "keyfleet", chain \\ 8453, path \\ @path),
    do:
      SignedAgentHelpers.sign(
        c.signer,
        c.secret,
        Siwa.Contract.authority(c.app),
        "POST",
        path,
        body,
        audience,
        chain
      )

  defp send_request(c, request),
    do:
      Req.post!(c.app <> request.path,
        headers: request.headers,
        body: request.body,
        retry: false,
        redirect: false
      )

  defp server(id, plug), do: SignedAgentHelpers.serve!(id, plug)

  defp digest(body), do: Siwa.content_digest_for_body(body)
end
