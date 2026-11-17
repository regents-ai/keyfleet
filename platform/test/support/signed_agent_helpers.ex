defmodule KeyfleetWeb.SignedAgentHelpers do
  @moduledoc """
  A local sign-in server that checks each signed request the way the real one
  does, and the agent requests it accepts, for tests of signed routes.
  """
  import ExUnit.Assertions
  import Plug.Conn

  @client_hint "Update your sign-in client, then send the request again."

  @doc """
  Starts the sign-in server under the calling test and points Keyfleet at it.
  Each request's payload reaches `test` as `{:broker_payload, payload}`.
  """
  def start_broker!(test, secret),
    do: start_broker!(:broker, test, &verdict(&1, secret))

  @doc """
  Starts a sign-in server that refuses as the real one does, with the status,
  code and message `Siwa.Contract.refusal/1` gives each reason, and points
  Keyfleet at it. Each request's payload reaches `test` as
  `{:broker_payload, payload}`.
  """
  def start_real_broker!(test, secret),
    do: start_broker!(:real_broker, test, &real_verdict(&1, secret))

  defp start_broker!(id, test, verdict) do
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    url = serve!(id, &verify(&1, &2, test, verdict))
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
  `method path` with `body`, sent to `authority` (`Siwa.Contract.authority/1`)
  and signed by `signer` under a fresh receipt for `audience` on `chain`,
  carrying a cookie and a bearer token the site must not forward.
  """
  def sign(signer, secret, authority, method, path, body, audience \\ "keyfleet", chain \\ 8453) do
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
          authority: authority,
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

  @doc """
  `method path` signed as `sign/8` signs it with no body, but declaring the
  empty body's `content-digest`, as a client that signs every request over
  its body signs a read. The library's own signer leaves that header out.
  """
  def sign_empty_digest(signer, secret, authority, method, path) do
    signed = sign(signer, secret, authority, method, path, "{}")
    empty = Siwa.RequestAuth.content_digest_for_body("")
    headers = Map.put(signed.headers, Siwa.Contract.body_component(), empty)
    {:ok, message} = Siwa.RequestAuth.signing_message(%{signed | headers: headers})
    {:ok, "0x" <> hex} = Siwa.LocalSigner.sign_message(signer, message)

    signature =
      "#{Siwa.Contract.label()}=:#{hex |> Base.decode16!(case: :mixed) |> Base.encode64()}:"

    %{signed | body: "", headers: Map.put(headers, Siwa.Contract.signature_header(), signature)}
  end

  @doc """
  The six ways a signed request's `content-digest` and the body that arrives
  can meet, in this order, each as `{case, request}` with `request.body` the
  bytes to send: `body` is a real body, and `other` a different one.
  """
  def body_cases(signer, secret, authority, method, path, body, other) do
    sign = &sign(signer, secret, authority, method, path, &1)

    [
      no_digest_no_body: sign.(nil),
      empty_digest_no_body: sign_empty_digest(signer, secret, authority, method, path),
      no_digest_real_body: %{sign.(nil) | body: body},
      real_digest_matching_body: sign.(body),
      real_digest_no_body: %{sign.(body) | body: ""},
      real_digest_different_body: %{sign.(body) | body: other}
    ]
    |> Enum.map(fn {name, request} -> {name, %{request | body: request.body || ""}} end)
  end

  @doc """
  Asserts the sign-in server heard, for each of `cases` in turn, the digest
  of exactly the bytes sent: none for the empty body.
  """
  def assert_reported_bytes!(cases) do
    for {name, %{body: body}} <- cases do
      assert_receive {:broker_payload, payload}
      digest = if body == "", do: nil, else: Siwa.content_digest_for_body(body)
      assert payload["body_digest"] == digest, "#{name}"
    end
  end

  defp verify(conn, _opts, test, verdict) do
    assert conn.request_path == "/api/shared/siwa/http-verify"
    assert get_req_header(conn, "x-siwa-audience") == ["keyfleet"]
    {:ok, raw, conn} = read_body(conn)
    assert byte_size(raw) <= 65_536
    payload = Jason.decode!(raw)
    send(test, {:broker_payload, payload})
    {status, body} = verdict.(payload)
    answer(conn, status, body)
  end

  @doc """
  The request in `payload`, the JSON the site sends the sign-in server, as
  siwa-server hands it to the library: its method, path, the host it reached,
  headers and the digest of its body. A stand-in serves Keyfleet at whatever
  host a test sends to, so it lists that host as the site's own
  (`authorities: [payload["authority"]]`).
  """
  def siwa_request(payload) do
    %{
      method: payload["method"],
      path: payload["path"],
      authority: payload["authority"],
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
    case check(payload, secret) do
      {:ok, verified} -> granted(verified, payload)
      {:error, _} -> {401, %{error: refusal()}}
    end
  end

  defp real_verdict(payload, secret) do
    case check(payload, secret) do
      {:ok, verified} ->
        granted(verified, payload)

      {:error, reason} ->
        {status, code, message} = Siwa.Contract.refusal(reason)
        {status, %{error: %{code: code, message: message, hint: @client_hint}}}
    end
  end

  defp check(payload, secret),
    do:
      Siwa.verify_authenticated_request(siwa_request(payload),
        secret: secret,
        audience: "keyfleet",
        wallet_audiences: ["keyfleet"],
        authorities: [payload["authority"]]
      )

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

  @doc "The hint `start_real_broker!/2`'s sign-in server gives with each refusal."
  def client_hint, do: @client_hint

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
