defmodule KeyfleetWeb.SignedAgentHelpers do
  @moduledoc """
  A local sign-in server that checks each signed request the way the real one
  does, and the agent requests it accepts, for tests of signed routes.
  """
  import ExUnit.Assertions
  import Plug.Conn

  @doc """
  Starts the sign-in server under the calling test and points Keyfleet at it.
  Each request's payload reaches `test` as `{:broker_payload, payload}`.
  """
  def start_broker!(test, secret) do
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    url = serve!(:broker, &verify(&1, &2, test, secret))
    Application.put_env(:keyfleet, :siwa_broker_url, url)
    url
  end

  @doc "Serves `plug` on a free local port under the calling test and returns its address."
  def serve!(id, plug), do: "http://127.0.0.1:#{listen!(id, plug, {127, 0, 0, 1})}"

  @doc """
  Serves `plug` on IPv6 only and returns an address by name, as Fly's private
  addresses are: a client that looks the name up over IPv4 never reaches it.
  """
  def serve_ipv6!(id, plug), do: "http://localhost:#{listen!(id, plug, {0, 0, 0, 0, 0, 0, 0, 1})}"

  defp listen!(id, plug, ip) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: ip, port: 0}, id: id)
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  `method path` with `body`, signed by `signer` under a fresh receipt for
  `audience` on `chain`, carrying a cookie and a bearer token the site must
  not forward.
  """
  def sign(signer, secret, method, path, body, audience \\ "keyfleet", chain \\ 8453) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => signer.address,
          "chain_id" => chain,
          "aud" => audience,
          "key_id" => signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: secret
      )

    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{
          method: method,
          path: path,
          body: body,
          headers: %{
            "content-type" => "application/json",
            "cookie" => "untrusted=1",
            "authorization" => "Bearer untrusted"
          }
        },
        receipt,
        signer,
        secret: secret,
        audience: audience,
        wallet_audiences: [audience]
      )

    request
  end

  defp verify(conn, _opts, test, secret) do
    assert conn.request_path == "/api/shared/siwa/http-verify"
    assert get_req_header(conn, "x-siwa-audience") == ["keyfleet"]
    {:ok, raw, conn} = read_body(conn)
    assert byte_size(raw) <= 65_536
    payload = Jason.decode!(raw)
    send(test, {:broker_payload, payload})
    {status, body} = verdict(payload, secret)
    answer(conn, status, body)
  end

  @doc """
  The request in `payload`, the JSON the site sends the sign-in server, as
  siwa-server hands it to the library: its method, path, headers and the
  digest of its body.
  """
  def siwa_request(payload) do
    %{
      method: payload["method"],
      path: payload["path"],
      headers: payload["headers"],
      body_digest: payload["body_digest"]
    }
  end

  @doc """
  The sign-in server's answer when asked to verify `payload`, a request signed
  under a receipt made with `secret`: `{200, verdict}` naming the wallet that
  signed it, or `{401, refusal}` when the signature does not hold. The browser
  test server's stand-in sign-in server answers with it too
  (`Keyfleet.BrowserAgents`).
  """
  def verdict(payload, secret) do
    case Siwa.verify_authenticated_request(siwa_request(payload),
           secret: secret,
           audience: "keyfleet",
           wallet_audiences: ["keyfleet"]
         ) do
      {:ok, verified} -> granted(verified, payload)
      {:error, _} -> {401, %{error: refusal()}}
    end
  end

  @doc """
  The sign-in server's `{200, verdict}` for `payload` once it has verified it.
  A request verifies once: the sign-in server refuses the same signature again.
  """
  def granted(%{claims: claims, covered_components: covered}, payload) do
    {200,
     %{
       code: "http_envelope_valid",
       data: %{
         verified: true,
         walletAddress: claims["sub"],
         chainId: claims["chain_id"],
         verificationMethod: "eoa_recovery",
         keyId: claims["key_id"],
         receiptExpiresAt:
           DateTime.from_unix!(claims["exp"], :millisecond) |> DateTime.to_iso8601(),
         requiredHeaders: Siwa.required_authenticated_request_headers(payload["body_digest"]),
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
     }}
  end

  # The sign-in server's refusal of a request whose signature does not hold.
  def refusal do
    %{
      "code" => "http_signature_invalid",
      "message" => "The request signature did not verify.",
      "hint" => "Sign the request again with your agent key, then send it."
    }
  end

  defp answer(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
