defmodule KeyFleetWeb.AgentPairingJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys

  @join_path "/api/v1/agent/join/status"
  @pairings_path "/api/v1/agent/pairings"
  @pairing_path "/api/v1/agent/keys/fibonacci_syndicate/1/pairing"
  @join_body ~s({ "name": "Wallet agent", "declared_harness": "local" })
  @owner "0x" <> String.duplicate("a", 40)

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(KeyFleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!("fibonacci_syndicate")

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

  test "a signed agent asks for a key, sees the request and takes it back again", c do
    assert send_signed(c, "POST", @pairing_path).body == %{"error" => "profile_not_found"}
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    missing_key = send_signed(c, "POST", "/api/v1/agent/keys/fibonacci_syndicate/7/pairing")
    assert missing_key.status == 404
    assert missing_key.body == %{"error" => "key_not_found"}

    requested = send_signed(c, "POST", @pairing_path)
    assert requested.status == 200

    assert %{
             "status" => "requested",
             "ownership_epoch" => 0,
             "owner_wallet" => @owner,
             "effective?" => false
           } = requested.body["pairing"]

    assert requested.body["pairing"]["operator_wallet"] == c.signer.address
    listed = send_signed(c, "GET", @pairings_path)
    assert listed.status == 200
    assert listed.body["pairings"] == [requested.body["pairing"]]

    withdrawn = send_signed(c, "DELETE", @pairing_path)
    assert withdrawn.status == 200
    assert withdrawn.body["pairing"]["id"] == requested.body["pairing"]["id"]
    assert withdrawn.body["pairing"]["status"] == "ended"
    assert withdrawn.body["pairing"]["ended_reason"] == "declined"

    repeated = send_signed(c, "DELETE", @pairing_path)
    assert repeated.status == 404
    assert repeated.body == %{"error" => "pairing_not_found"}
    assert send_signed(c, "GET", @pairings_path).body["pairings"] == [withdrawn.body["pairing"]]
  end

  test "only the canonical signed key path and empty body reach the pairing actions", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200

    for {method, path, body} <- [
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/1/pairing", ~s({"token_id":2})},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/01/pairing", "{}"},
          {"POST", "/api/v1/agent/keys/Fibonacci_syndicate/1/pairing", "{}"},
          {"POST", "/api/v1/agent/keys/fibonacci_syndicate/1/pairing/", "{}"},
          {"PUT", @pairing_path, "{}"},
          {"POST", @pairings_path, "{}"},
          {"GET", "/api/v1/agent/pairings?all=1", "{}"}
        ] do
      assert send_signed(c, method, path, body).status == 401
    end

    encoded = signed(c, "POST", "/api/v1/agent/keys/fibonacci_syndicate/1/p%61iring", "{}")
    assert deliver(c, encoded).status == 401
    assert send_signed(c, "POST", @pairing_path).status == 200
  end

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
