defmodule KeyfleetWeb.ProfileApiTest do
  # The person's shared profile at /api/v1/profile (RegentIdentity.HTTP), for the
  # owner KeyfleetWeb.Plugs.ProfileOwner names, every answer held to the contract:
  # - a person signed in here reads it and, with the forms token, saves their
  #   public name, which reads back; a change without the token is refused and
  #   changes nothing; signed out, a read and a change are refused, the
  #   change before its body is read, and the owner's broken or oversized
  #   change is refused with the profile API's own code;
  # - a person who signed in before sign-in made profiles has none, and saves
  #   once they sign in again;
  # - an agent the person paired reads and saves it for them; one paired with a
  #   person who has no account here is refused;
  # - a request with SIWA headers but no signature is the person's, not an agent's.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession
  alias Keyfleet.Actors.System
  alias Keyfleet.{ContractSchema, PairingHelpers}
  alias KeyfleetWeb.SignedAgentHelpers

  @path "/api/v1/profile"
  # The account Keyfleet.TestPrivyVerifier vouches for with the access token "valid".
  @person "did:privy:verified"
  @wallet "0x1111111111111111111111111111111111111111"

  test "a person signed in here saves their public name with the forms token, and reads it back" do
    signed_in = sign_in()

    assert %{"profile" => %{"display_name" => nil}} =
             signed_in |> again() |> read() |> answer(200)

    saved = signed_in |> again() |> with_forms_token() |> change(%{display_name: "Ada"})
    assert %{"profile" => %{"display_name" => "Ada"}} = answer(saved, 200)

    assert %{"profile" => %{"display_name" => "Ada"}} =
             signed_in |> again() |> read() |> answer(200)
  end

  test "a change without the forms token is refused and changes nothing" do
    signed_in = sign_in()

    refused = signed_in |> again() |> enforce_csrf() |> change(%{display_name: "Forged"})
    assert %{"error" => %{"code" => "authentication_required"}} = answer(refused, 401)

    assert %{"profile" => %{"display_name" => nil}} =
             signed_in |> again() |> read() |> answer(200)
  end

  test "signed out, a read and a change are refused" do
    assert %{"error" => %{"code" => "authentication_required"}} =
             build_conn() |> read() |> answer(401)

    assert %{"error" => %{"code" => "authentication_required"}} =
             build_conn()
             |> init_test_session(%{})
             |> with_forms_token()
             |> change(%{display_name: "Nobody"})
             |> answer(401)
  end

  test "a change's body is read only for its owner, who is told when it is broken or too large" do
    signed_in = sign_in()
    oversized = Jason.encode!(%{display_name: String.duplicate("a", 8192)})

    for {body, status, code} <- [
          {"{", 400, "invalid_profile_json"},
          {oversized, 413, "profile_request_too_large"}
        ] do
      assert %{"error" => %{"code" => ^code}} =
               signed_in |> again() |> with_forms_token() |> send_change(body) |> answer(status)

      assert %{"error" => %{"code" => "authentication_required"}} =
               build_conn() |> send_change(body) |> answer(401)
    end
  end

  test "a person who signed in before sign-in made profiles saves once they sign in again" do
    {:ok, account} = Accounts.register_verified(@person, @wallet, [@wallet], actor: %System{})
    before = fn -> init_test_session(build_conn(), %{human_account_id: account.id}) end

    assert %{"error" => %{"code" => "profile_not_created"}} = before.() |> read() |> answer(404)

    assert %{"error" => %{"code" => "invalid_profile_update"}} =
             before.() |> with_forms_token() |> change(%{display_name: "Ada"}) |> answer(422)

    signed_in = sign_in()
    saved = signed_in |> again() |> with_forms_token() |> change(%{display_name: "Ada"})
    assert %{"profile" => %{"display_name" => "Ada"}} = answer(saved, 200)
  end

  test "an agent the person paired reads and saves their public name for them" do
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    {:ok, signer} = Siwa.LocalSigner.new()
    person_wallet = wallet()
    PairingHelpers.pair_wallet!(String.downcase(signer.address), person_wallet)
    account = signs_in("did:privy:test-" <> person_wallet, person_wallet)

    assert %{"profile" => %{"display_name" => nil, "linked_wallets" => [^person_wallet]}} =
             signer |> signed(secret, "GET", nil) |> answer(200)

    saved = signed(signer, secret, "PATCH", %{display_name: "Scout's person"})
    assert %{"profile" => %{"display_name" => "Scout's person"}} = answer(saved, 200)

    assert %{"profile" => %{"display_name" => "Scout's person"}} =
             build_conn()
             |> init_test_session(%{human_account_id: account.id})
             |> read()
             |> answer(200)

    {:ok, stranger} = Siwa.LocalSigner.new()
    pair_elsewhere(String.downcase(stranger.address))

    assert %{"error" => %{"code" => "person_not_here"}} =
             stranger |> signed(secret, "GET", nil) |> answer(403)

    assert %{"error" => %{"code" => "person_not_here"}} =
             stranger |> signed(secret, "PATCH", %{display_name: "Nobody"}) |> answer(403)
  end

  test "a request with SIWA headers but no signature is the person's, not an agent's" do
    SignedAgentHelpers.start_broker!(self(), :crypto.strong_rand_bytes(32))
    signed_in = sign_in()

    for unsigned <- [
          [{"content-digest", Siwa.content_digest_for_body("{}")}],
          [{"x-key-id", wallet()}, {"x-timestamp", "1"}]
        ] do
      assert %{"profile" => %{"display_name" => nil}} =
               signed_in |> again() |> with_headers(unsigned) |> read() |> answer(200)

      assert %{"error" => %{"code" => "authentication_required"}} =
               build_conn() |> with_headers(unsigned) |> read() |> answer(401)
    end

    refute_received {:broker_payload, _payload}
  end

  # The site's own sign-in step, as the page takes it, for the account `@person`.
  defp sign_in do
    signed_in =
      build_conn()
      |> init_test_session(%{})
      |> with_forms_token()
      |> put_req_header("authorization", "Bearer valid")
      |> put_req_header("privy-id-token", Keyfleet.TestPrivyVerifier.identity_token("valid"))
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(signed_in, 200)
    signed_in
  end

  # A sign-in of `person`, as the sign-in step makes it once Privy vouches for them.
  defp signs_in(person, wallet) do
    now = Elixir.System.system_time(:second)

    {:ok, account, []} =
      VerifiedSession.establish(%RegentPrivy.Session{
        app_id: Application.fetch_env!(:keyfleet, :privy)[:app_id],
        privy_user_id: person,
        session_id: "session-" <> wallet,
        wallet_address: wallet,
        wallet_addresses: [wallet],
        issued_at: now,
        expires_at: now + 600
      })

    account
  end

  # An agent paired with a person who has never signed in here.
  defp pair_elsewhere(agent_wallet) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: "did:privy:elsewhere-" <> agent_wallet}
      )

    RegentAgents.pair_agent!(code, "Test agent", :codex,
      actor: %RegentAgents.Agent{wallet: agent_wallet}
    )
  end

  # The browser's next request, with the cookie `signed_in` set.
  defp again(signed_in), do: init_test_session(build_conn(), get_session(signed_in))

  defp with_forms_token(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> enforce_csrf()
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end

  defp enforce_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp with_headers(conn, headers),
    do:
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

  defp read(conn), do: get(conn, @path)

  defp change(conn, body), do: send_change(conn, Jason.encode!(body))

  defp send_change(conn, raw) do
    conn
    |> put_req_header("content-type", "application/json")
    |> patch(@path, raw)
  end

  defp signed(signer, secret, method, body) do
    raw = body && Jason.encode!(body)
    request = SignedAgentHelpers.sign(signer, secret, "www.example.com", method, @path, raw)

    request.headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> dispatch(@endpoint, method, @path, raw)
  end

  defp answer(conn, status) do
    assert conn.status == status
    body = Jason.decode!(conn.resp_body)
    assert ContractSchema.response_errors(body, conn.method, @path, status) == []
    body
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
