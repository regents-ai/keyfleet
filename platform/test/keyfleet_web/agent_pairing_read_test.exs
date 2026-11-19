defmodule KeyfleetWeb.AgentPairingReadTest do
  # The SIWA service's question before it gives an agent a hello card naming
  # Keyfleet, POST /api/agents/v1/pairing, through the site's own endpoint and
  # router: with the service's token for this site's own address, a paired
  # agent is answered with its name, its person's profile code and when it
  # paired; an agent paired nowhere here is not found; a paired agent whose
  # person has no profile yet is told so; and without a token for this site,
  # nothing is answered. The SIWA service's published keys are a stand-in.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession

  @kid "siwa-1"
  @held {RegentAgents.HelloCard, :keys}

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    # The published keys are kept for an hour across tests; each test reads its own.
    :persistent_term.erase(@held)
    on_exit(fn -> :persistent_term.erase(@held) end)

    Req.Test.stub(RegentAgents.Broker, fn
      %{method: "GET", request_path: "/.well-known/jwks.json"} = conn ->
        Req.Test.json(conn, %{
          "keys" => [
            %{
              "kty" => "OKP",
              "crv" => "Ed25519",
              "kid" => @kid,
              "x" => Base.url_encode64(public, padding: false)
            }
          ]
        })
    end)

    %{private: private}
  end

  test "a paired agent is answered with its name, its person's profile code and when it paired",
       c do
    did = "did:privy:pairing-read-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    signed_in_once!(did)
    pair!(did, wallet, "Scout")
    {:ok, profile} = RegentIdentity.profile_id("keyfleet-test", did)

    answer = ask(c, subject(wallet))
    assert answer.status == 200

    assert %{"name" => "Scout", "person" => ^profile, "pairedAt" => paired_at} =
             body = Jason.decode!(answer.resp_body)

    assert map_size(body) == 3
    assert {:ok, _at, 0} = DateTime.from_iso8601(paired_at)
  end

  test "an agent paired nowhere here is not found, nor one on another chain", c do
    wallet = new_wallet()

    for subject <- [subject(wallet), "eip155:1:" <> wallet] do
      answer = ask(c, subject)
      assert answer.status == 404
      assert error(answer) == "not_paired_here"
    end
  end

  test "a paired agent whose person has no profile yet is told so", c do
    did = "did:privy:pairing-read-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    Accounts.register_verified!(did, wallet, [wallet], actor: %Keyfleet.Actors.System{})
    pair!(did, wallet, "Scout")

    answer = ask(c, subject(wallet))
    assert answer.status == 409
    assert error(answer) == "person_has_no_profile"
  end

  test "without the service's token for this site and this agent, nothing is answered", c do
    did = "did:privy:pairing-read-" <> Ecto.UUID.generate()
    wallet = new_wallet()
    signed_in_once!(did)
    pair!(did, wallet, "Scout")
    subject = subject(wallet)

    for token <- [
          nil,
          service_token(c, subject, %{"aud" => "https://elsewhere.example"}),
          service_token(c, subject(new_wallet())),
          service_token(c, subject, %{"exp" => System.system_time(:second) - 1})
        ] do
      answer = ask(subject, token)
      assert answer.status == 401
      assert error(answer) == "service_token_invalid"
    end
  end

  # The SIWA service asks about `subject` with its token for this site.
  defp ask(c, subject) when is_map(c), do: ask(subject, service_token(c, subject))

  defp ask(subject, token) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, "/api/agents/v1/pairing", Jason.encode!(%{"subject" => subject}))
  end

  # The service's token: issued by the SIWA service for this site's own
  # address and `subject`, for 60 seconds; `changes` changes any claim.
  defp service_token(c, subject, changes \\ %{}) do
    claims =
      Map.merge(
        %{
          "iss" => :regent_agents |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:url),
          "aud" => KeyfleetWeb.Endpoint.url(),
          "sub" => subject,
          "exp" => System.system_time(:second) + 60
        },
        changes
      )

    header = encode(%{"alg" => "EdDSA", "typ" => "siwa-service+jwt", "kid" => @kid})
    payload = encode(claims)
    signature = :crypto.sign(:eddsa, :none, header <> "." <> payload, [c.private, :ed25519])
    header <> "." <> payload <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  # A person's first sign-in with a wallet, which gives them their profile.
  defp signed_in_once!(did) do
    wallet = new_wallet()
    now = System.system_time(:second)

    {:ok, _account, []} =
      VerifiedSession.establish(%RegentPrivy.Session{
        app_id: "keyfleet-test",
        privy_user_id: did,
        session_id: "session-" <> did,
        wallet_address: wallet,
        wallet_addresses: [wallet],
        linked_socials: [],
        issued_at: now,
        expires_at: now + 3600
      })
  end

  defp pair!(did, wallet, name) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: did})

    RegentAgents.pair_agent!(code, name, :codex, actor: %RegentAgents.Agent{wallet: wallet})
  end

  defp subject(wallet), do: "eip155:8453:" <> wallet
  defp error(answer), do: Jason.decode!(answer.resp_body)["error"]["code"]
  defp new_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
