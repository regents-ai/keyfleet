defmodule KeyfleetWeb.AgentPairingJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys

  @join_path "/api/v1/agent/join/status"
  @pairings_path "/api/v1/agent/pairings"
  @pairing_path "/api/v1/agent/keys/fibonacci_syndicate/1/pairing"
  @step_down_path "/api/v1/agent/keys/fibonacci_syndicate/1/step-down"
  @join_body ~s({ "name": "Wallet agent", "declared_harness": "local" })
  @owner "0x" <> String.duplicate("a", 40)

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!("fibonacci_syndicate")
    ChainHelpers.seed_cursor!("fibonacci_syndicate")

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
             "ownership_epoch" => 1,
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

  test "a signed agent steps down from the key it runs, once", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    assert send_signed(c, "POST", @step_down_path).body == %{"error" => "pairing_not_found"}

    requested = send_signed(c, "POST", @pairing_path).body["pairing"]
    assert send_signed(c, "POST", @step_down_path).status == 404

    [request] = Keys.list_pairing_requests!("fibonacci_syndicate", 1)

    Keys.approve_pairing!(request, Keys.default_limits(),
      actor: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    )

    stepped_down = send_signed(c, "POST", @step_down_path)
    assert stepped_down.status == 200

    assert %{
             "status" => "ended",
             "ended_reason" => "stepped_down",
             "effective?" => false,
             "ended_at" => ended_at
           } = stepped_down.body["pairing"]

    assert stepped_down.body["pairing"]["id"] == requested["id"]
    assert is_binary(ended_at)
    assert Keys.current_operator!("fibonacci_syndicate", 1) == nil

    repeated = send_signed(c, "POST", @step_down_path)
    assert repeated.status == 404
    assert repeated.body == %{"error" => "pairing_not_found"}

    nowhere = send_signed(c, "POST", "/api/v1/agent/keys/hull_survey/1/step-down")
    assert nowhere.body == %{"error" => "fleet_unknown"}

    for body <- [~s({"token_id":1}), ~s({"reason":"done"})],
        do: assert(send_signed(c, "POST", @step_down_path, body).status == 401)
  end

  test "a signed agent reads the limits its owner wrote, as the contract describes them", c do
    assert send_signed(c, "POST", @join_path, @join_body).status == 200
    requested = send_signed(c, "POST", @pairing_path).body["pairing"]
    assert requested["limits"] == nil

    [request] = Keys.list_pairing_requests!("fibonacci_syndicate", 1)
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    approved = Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)

    Keys.set_limits!(approved, %{Keys.default_limits() | money: "Spend up to nothing."},
      actor: owner
    )

    listed = send_signed(c, "GET", @pairings_path)
    assert ContractSchema.response_errors(listed.body, "GET", @pairings_path, 200) == []
    assert [%{"id" => id, "limits" => limits}] = listed.body["pairings"]
    assert id == requested["id"]

    assert %{
             "money" => "Spend up to nothing.",
             "your_information" => "Don't share anything about me" <> _,
             "outside_keyfleet" => "Don't sign up for anything" <> _,
             "check_with_owner_first" => "Before agreeing to a deadline" <> _,
             "written_at" => written_at
           } = limits

    assert {:ok, _at, 0} = DateTime.from_iso8601(written_at)
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
