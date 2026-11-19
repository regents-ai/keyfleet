defmodule KeyfleetWeb.HelloCardTest do
  # Hello cards (RegentAgents.HelloCard), through the site's own endpoint and
  # router:
  # - the SIWA service's question before it gives an agent a card naming
  #   Keyfleet, POST /api/agents/v1/pairing: with the service's token for this
  #   site's own address, a paired agent is answered with its name, its
  #   person's profile code and when it paired; an agent paired nowhere here is
  #   not found; a paired agent whose person has no profile yet is told so; and
  #   without a token for this site, nothing is answered;
  # - a card beside an agent's own signed request, on the API and at /mcp: kept
  #   when it passes for that agent's wallet, and otherwise left out, the
  #   request answered as without it.
  # The SIWA service's published keys are a stand-in, as is the sign-in server.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession
  alias Keyfleet.PairingHelpers
  alias KeyfleetWeb.SignedAgentHelpers

  @kid "siwa-1"
  @held {RegentAgents.HelloCard, :keys}
  @card "siwa-hello-card+jws"

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

  describe "the pairing read" do
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
  end

  describe "a card beside a signed request" do
    setup do
      secret = :crypto.strong_rand_bytes(32)
      SignedAgentHelpers.start_broker!(self(), secret)
      {:ok, signer} = Siwa.LocalSigner.new()
      wallet = String.downcase(signer.address)
      PairingHelpers.pair_wallet!(wallet)

      %{
        secret: secret,
        signer: signer,
        wallet: wallet,
        from: {198, 51, 100, :rand.uniform(250)}
      }
    end

    test "on the API is kept when it passes for the agent's own wallet, and left out otherwise",
         c do
      fields = card_fields(subject(c.wallet))
      shown = shards(c, card(c, fields))
      assert shown.status == 200
      assert shown.assigns.hello_card == fields

      for card <- refused_cards(c) do
        conn = shards(c, card)
        assert conn.status == 200
        assert conn.resp_body == shown.resp_body
        assert conn.assigns.hello_card == nil
      end
    end

    test "at /mcp is kept when it passes for the agent's own wallet, and left out otherwise",
         c do
      connector_on()
      fields = card_fields(subject(c.wallet))
      shown = tools_list(c, card(c, fields))
      assert shown.status == 200
      assert [_ | _] = Jason.decode!(shown.resp_body)["result"]["tools"]
      assert shown.assigns.hello_card == fields

      for card <- refused_cards(c) do
        conn = tools_list(c, card)
        assert conn.status == 200
        assert conn.resp_body == shown.resp_body
        assert conn.assigns.hello_card == nil
      end
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

    sign(c.private, "siwa-service+jwt", claims)
  end

  # A card's eight fields for `subject`, issued an hour ago and good until
  # `expires_in` seconds from now.
  defp card_fields(subject, expires_in \\ 86_400) do
    now = DateTime.utc_now()

    %{
      "cardId" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "subject" => subject,
      "name" => "Scout",
      "person" => "profile-" <> Ecto.UUID.generate(),
      "pairedAt" => iso(DateTime.add(now, -86_400)),
      "pairedOn" => "https://elsewhere.example",
      "issuedAt" => iso(DateTime.add(now, -3_600)),
      "expiresAt" => iso(DateTime.add(now, expires_in))
    }
  end

  defp card(c, fields), do: sign(c.private, @card, fields)

  # Cards that do not pass for the agent: one for another wallet, an expired
  # one, one signed by a key the service never published, the service's token
  # shown as a card, and none.
  defp refused_cards(c) do
    {_public, unpublished} = :crypto.generate_key(:eddsa, :ed25519)

    [
      card(c, card_fields(subject(new_wallet()))),
      card(c, card_fields(subject(c.wallet), -1)),
      sign(unpublished, @card, card_fields(subject(c.wallet))),
      service_token(c, subject(c.wallet)),
      nil
    ]
  end

  defp sign(private, typ, claims) do
    header = encode(%{"alg" => "EdDSA", "typ" => typ, "kid" => @kid})
    payload = encode(claims)
    signature = :crypto.sign(:eddsa, :none, header <> "." <> payload, [private, :ed25519])
    header <> "." <> payload <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
  defp iso(time), do: time |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The agent's own signed read of its shards, with `card` beside it.
  defp shards(c, card), do: signed(c, "GET", "/api/v1/agent/shards", nil, card)

  # The agent's own signed tools/list at /mcp, with `card` beside it.
  defp tools_list(c, card) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    signed(c, "POST", "/mcp", body, card)
  end

  defp signed(c, method, path, body, card) do
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", method, path, body)

    conn =
      request.headers
      |> Map.drop(["cookie", "authorization"])
      |> Enum.reduce(%{build_conn() | remote_ip: c.from}, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn = if card, do: put_req_header(conn, "x-siwa-hello-card", card), else: conn
    dispatch(conn, @endpoint, method, path, body)
  end

  # The connector on, as far as an agent signing its own requests needs it.
  defp connector_on do
    oauth = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(oauth, :enabled?, true))
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, oauth) end)
  end

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
