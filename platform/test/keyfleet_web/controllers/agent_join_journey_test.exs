defmodule KeyfleetWeb.AgentJoinJourneyTest do
  use ExUnit.Case, async: false
  import KeyfleetWeb.RefusalHelpers
  import Plug.Conn
  @path "/api/v1/agent/join/status"
  @update_path "/api/v1/agent/profile/update"
  @body ~s({ "name": "Wallet agent", "declared_harness": "local" })

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    test = self()
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)

    broker =
      server(:broker, fn conn, _ ->
        assert conn.request_path == "/api/shared/siwa/http-verify"
        assert get_req_header(conn, "x-siwa-audience") == ["keyfleet"]
        {:ok, raw, conn} = read_body(conn)
        assert byte_size(raw) <= 65_536
        payload = Jason.decode!(raw)
        send(test, {:broker_payload, payload})

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

          {:error, _} ->
            answer(conn, 401, %{error: %{code: "invalid_proof"}})
        end
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, broker)
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "only the exact signed wallet request creates or resumes its unchanged profile", c do
    signed = signed(c, @body)
    changed = String.replace(@body, "Wallet agent", "Changed agent")
    assert send_request(c, %{signed | body: changed}).status == 401
    first = send_request(c, signed)
    assert first.status == 200
    profile = first.body["profile"]
    assert profile["wallet_address"] == c.signer.address
    assert profile["name"] == "Wallet agent"
    assert send_request(c, signed).status == 401
    resumed = send_request(c, signed(c, changed))
    assert resumed.status == 200
    assert resumed.body["profile"] == profile
    assert_receive {:broker_payload, %{"body" => ^changed}}

    assert_receive {:broker_payload,
                    %{"body" => @body, "method" => "POST", "path" => @path, "headers" => headers}}

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

  test "signed edits preserve ownership and database activity/status timestamp semantics", c do
    initial = send_request(c, signed(c, @body)).body["profile"]

    edit =
      ~s({ "name": "Updated", "current_status": "Working", "avatar": null, "proficiencies": ["Elixir"] })

    request = signed(c, edit, "keyfleet", 8453, @update_path)

    assert send_request(c, %{request | body: String.replace(edit, "Updated", "Tampered")}).status ==
             401

    response = send_request(c, request)
    assert response.status == 200
    updated = response.body["profile"]
    assert updated["id"] == initial["id"]
    assert updated["wallet_address"] == initial["wallet_address"]
    assert updated["name"] == "Updated"
    assert updated["avatar"] == nil
    assert updated["proficiencies"] == ["Elixir"]
    assert later?(updated["last_activity_at"], initial["last_activity_at"])
    assert later?(updated["status_updated_at"], initial["status_updated_at"])
    assert send_request(c, request).status == 401
    renamed = update(c, %{name: "Renamed"}).body["profile"]
    assert renamed["status_updated_at"] == updated["status_updated_at"]
    assert later?(renamed["last_activity_at"], updated["last_activity_at"])
    repeated = update(c, %{current_status: "Working"}).body["profile"]
    assert later?(repeated["status_updated_at"], renamed["status_updated_at"])
    assert update(c, %{name: nil}).status == 422
    assert send_request(c, signed(c, @body)).body["profile"] == repeated

    {:ok, other_signer} = Siwa.LocalSigner.new()
    other = %{c | signer: other_signer}
    missing = update(other, %{name: "Cannot target first wallet"})
    assert missing.status == 404
    assert missing.body == refused("profile_not_found")
    assert update(other, %{id: initial["id"], name: "Denied"}).status == 401
    own = send_request(other, signed(other, @body)).body["profile"]
    other_edit = update(other, %{name: "Second wallet"}).body["profile"]
    assert other_edit["id"] == own["id"]
    assert other_edit["id"] != initial["id"]
    assert send_request(c, signed(c, @body)).body["profile"] == repeated
  end

  test "update rejects empty or immutable input before verification and enforces the envelope budget",
       c do
    request = signed(c, "{}", "keyfleet", 8453, @update_path)

    for body <- [
          "{}",
          "[]",
          "",
          ~s({"id":"forged"}),
          ~s({"wallet_address":"forged"}),
          ~s({"last_activity_at":"forged"}),
          ~s({"status_updated_at":"forged"}),
          ~s({"unknown":"forged"})
        ] do
      assert send_request(c, %{request | body: body}).status == 401
    end

    oversized = %{request | body: String.duplicate(" ", 24 * 1024 + 1)}
    assert send_request(c, oversized).status == 413

    valid = signed(c, ~s({"name":"Updated"}), "keyfleet", 8453, @update_path)

    for {method, path} <- [
          {:get, @update_path},
          {:post, @update_path <> "?id=forged"},
          {:post, "/api/v1/agent/profile/%75pdate"}
        ] do
      assert Req.request!(
               method: method,
               url: c.app <> path,
               headers: valid.headers,
               body: valid.body,
               retry: false,
               redirect: false
             ).status == 401
    end

    assert send_request(c, %{
             valid
             | headers: Map.put(valid.headers, "x-agent-token-id", "forged")
           }).status == 401

    refute_receive {:broker_payload, _}
    assert send_request(c, signed(c, @body)).status == 200
    assert_receive {:broker_payload, _}
    # JSON escaping nearly doubles this real profile input inside the broker envelope.
    raw = Jason.encode!(%{proficiencies: List.duplicate(String.duplicate("\\", 2000), 6)})
    padded = raw <> String.duplicate(" ", 24 * 1024 - byte_size(raw))
    at_limit = signed(c, padded, "keyfleet", 8453, @update_path)
    assert send_request(c, at_limit).status == 200
    assert_receive {:broker_payload, %{"body" => ^padded} = payload}
    assert byte_size(Jason.encode!(payload)) < 65_536
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
    assert_receive {:broker_payload, %{"body" => @body}}

    oversized =
      Req.post!(c.app <> @path,
        headers: request.headers,
        body: Stream.repeatedly(fn -> String.duplicate("x", 1024) end) |> Stream.take(5),
        retry: false,
        redirect: false
      )

    assert oversized.status == 413
    refute_receive {:broker_payload, _}
    conn = Plug.Test.conn("POST", @path, @body)
    assert {:error, _} = KeyfleetWeb.Plugs.SignedAgent.before_verify(conn, %{})
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
    assert send_request(c, signed(c, @body)).status == 401
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
    assert response.body == refused("authentication_unavailable")
    assert_receive :unavailable_called
    refute_receive :unavailable_called
    stop_supervised!(:unavailable)
    assert send_request(c, signed(c, @body)).status == 503
  end

  test "the request boundary rejects ambiguity before it spends broker replay state", c do
    signed = signed(c, @body)

    for body <- [
          "",
          "{}",
          "[1]",
          "not json",
          ~s({"name":"a","declared_harness":"b","wallet":"x"}),
          ~s({"name":1,"declared_harness":"b"})
        ] do
      assert send_request(c, %{signed | body: body}).status == 401
    end

    assert send_request(c, %{signed | body: String.duplicate(" ", 4097)}).status == 413

    for header <- [
          "x-agent-registry-address",
          "x-agent-token-id",
          "x-agent-id",
          "x-siwa-audience"
        ] do
      assert send_request(c, %{signed | headers: Map.put(signed.headers, header, "untrusted")}).status ==
               401
    end

    for header <- KeyfleetWeb.Plugs.SignedAgent.proof_headers() do
      assert send_request(c, %{signed | headers: Map.delete(signed.headers, header)}).status ==
               401

      duplicate = Plug.Test.conn("POST", @path, @body)

      duplicate = %{
        duplicate
        | req_headers: [
            {String.upcase(header), signed.headers[header]} | Map.to_list(signed.headers)
          ]
      }

      assert KeyfleetWeb.Endpoint.call(duplicate, []).status == 401
    end

    for {method, path} <- [
          {:get, @path},
          {:put, @path},
          {:post, @path <> "?name=x"},
          {:post, "/api/v1/agent/other"},
          {:post, "/api/v1/%61gent/join/status"}
        ] do
      assert Req.request!(
               method: method,
               url: c.app <> path,
               headers: signed.headers,
               body: @body,
               retry: false,
               redirect: false
             ).status == 401
    end

    assert send_request(c, %{
             signed
             | headers: Map.put(signed.headers, "content-type", "text/plain")
           }).status == 401

    refute_receive {:broker_payload, _}
    assert send_request(c, signed).status == 200
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
      |> Plug.Conn.put_req_header("x-siwa-receipt", "receipt")
      |> Plug.Conn.put_req_header("x-key-id", wallet)

    # A plain wallet proves its key on either chain. A smart wallet is only
    # proven on the chain it was checked on, and keys are held on Ethereum.
    for {chain_id, method} <- [
          {8453, "eoa_recovery"},
          {1, "eoa_recovery"},
          {1, "erc1271"},
          {1, "erc6492"}
        ] do
      assert {:ok, %{assigns: %{agent_actor: actor}}} =
               KeyfleetWeb.Plugs.SignedAgent.accept(conn, signed_in.(chain_id, method), nil)

      assert {actor.chain_id, actor.verification_method} ==
               {chain_id, String.to_existing_atom(method)}
    end

    invalid =
      [
        Map.put(good, "verified", false),
        Map.put(good, "walletAddress", String.upcase(wallet)),
        Map.put(good, "chainId", 1),
        Map.delete(good, "verificationMethod"),
        Map.put(good, "verificationMethod", "passkey"),
        signed_in.(8453, "erc1271"),
        signed_in.(8453, "erc6492"),
        signed_in.(10, "eoa_recovery"),
        Map.put(good, "principal", nil),
        Map.put(good, "extra", true)
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
      assert response.body == refused("authentication_unavailable")
    end
  end

  defp signed(c, body, audience \\ "keyfleet", chain \\ 8453, path \\ @path) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => c.signer.address,
          "chain_id" => chain,
          "aud" => audience,
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
          method: "POST",
          path: path,
          body: body,
          headers: %{
            "content-type" => "application/json",
            "cookie" => "untrusted=1",
            "authorization" => "Bearer untrusted"
          }
        },
        receipt,
        c.signer,
        secret: c.secret,
        audience: audience,
        wallet_audiences: [audience]
      )

    request
  end

  defp send_request(c, request),
    do:
      Req.post!(c.app <> request.path,
        headers: request.headers,
        body: request.body,
        retry: false,
        redirect: false
      )

  defp server(id, plug) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: id)
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp update(c, params),
    do: send_request(c, signed(c, Jason.encode!(params), "keyfleet", 8453, @update_path))

  defp later?(new, old) do
    {:ok, new, _} = DateTime.from_iso8601(new)
    {:ok, old, _} = DateTime.from_iso8601(old)
    DateTime.compare(new, old) == :gt
  end

  defp answer(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
