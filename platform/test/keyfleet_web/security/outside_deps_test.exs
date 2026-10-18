defmodule KeyfleetWeb.Security.OutsideDepsTest do
  @moduledoc """
  Proofs for the three controls the 17 Oct red-team pass found outside this
  repository, run against the shared libraries' real code at the elixir-utils
  ref `mix.lock` pins (`docs/security/outside-dependencies-2026-10-18.md`):

    * Agent sign-in (`siwa`). The endpoint's real `Siwa.AgentAuthPlug` builds the
      request it asks the sign-in server about, and the local sign-in server
      checks it with `Siwa.RequestAuth`, the code siwa-server runs. Its record of
      used requests is the library's in-memory one; siwa-server keeps the same
      keys in Postgres.
    * Privy sign-in (`RegentPrivy.Session`), through `/auth/privy/session`.
    * Credits debits (`RegentCredits.hold`), on this site's database.

  Every refused request is checked again with the library to name why it was
  refused, so a test cannot pass on a refusal for some other reason.
  """
  use ExUnit.Case, async: false

  import KeyfleetWeb.RedTeamHelpers
  import KeyfleetWeb.SessionAuthorityHelpers
  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Plug.Conn

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System, as: SystemActor
  alias Keyfleet.SandboxRace
  alias KeyfleetWeb.SignedAgentHelpers
  alias RegentCredits.Actor
  alias RegentCredits.Errors.NotEnoughCredits

  @moduletag :capture_log

  @endpoint KeyfleetWeb.Endpoint

  @join_path "/api/v1/agent/join/status"
  @join %{"name" => "Probe", "declared_harness" => "local"}

  describe "agent sign-in binds each signature to one request (OD-SIWA)" do
    setup do
      ctx = start_app!()
      signer = paired_signer!()
      # The agent's wallet holds Keys 1 and 2, so a signature moved from one
      # Key's address to the other's would be acted on if the path were not
      # part of what it signs.
      record_owner!(1, signer.address)
      record_owner!(2, signer.address)
      ctx = Map.put(ctx, :signer, signer)
      send_signed(ctx, signer, "POST", @join_path, @join)
      assert_receive {:broker_payload, _join}
      {:ok, ctx}
    end

    test "OD-SIWA-REPLAY: a signed request is served once and refused when sent again", ctx do
      request = SignedAgentHelpers.sign(ctx.signer, ctx.secret, "POST", @join_path, body(@join))

      assert %{status: 200} = deliver(ctx, "POST", @join_path, request)
      assert_receive {:broker_payload, _first}

      assert deliver(ctx, "POST", @join_path, request).status == 401
      assert_receive {:broker_payload, again}
      assert reason(ctx, again) == :replayed_request
    end

    test "OD-SIWA-PATH: a signature for Key 1's address is refused at Key 2's, both held",
         ctx do
      own = "/api/v1/agent/fleets/#{fleet()}/keys/1/dms"
      other = "/api/v1/agent/fleets/#{fleet()}/keys/2/dms"
      request = SignedAgentHelpers.sign(ctx.signer, ctx.secret, "GET", own, nil)

      assert deliver(ctx, "GET", other, request).status == 401
      assert_receive {:broker_payload, %{"path" => ^other} = moved}
      # Over another path the signature recovers some other address, which
      # no agent is signed in as.
      assert reason(ctx, moved) == :signature_lookup_failed

      # Where it was signed for, the same request is served, so the refusal
      # above is the path's and nothing else's.
      assert %{status: 200} = deliver(ctx, "GET", own, request)
      assert_receive {:broker_payload, %{"path" => ^own}}
    end

    test "OD-SIWA-COMPONENTS: a genuine signature that leaves the path out is refused",
         ctx do
      own = "/api/v1/agent/fleets/#{fleet()}/keys/1/dms"
      other = "/api/v1/agent/fleets/#{fleet()}/keys/2/dms"

      pathless =
        ctx.signer
        |> SignedAgentHelpers.sign(ctx.secret, "GET", own, nil)
        |> sign_again_without("@path", ctx.signer)

      assert deliver(ctx, "GET", other, pathless).status == 401
      assert_receive {:broker_payload, %{"path" => ^other} = payload}
      assert reason(ctx, payload) == :missing_covered_components
    end

    test "OD-SIWA-AUDIENCE: a request signed in for another Regent site is refused here", ctx do
      request =
        SignedAgentHelpers.sign(
          ctx.signer,
          ctx.secret,
          "POST",
          @join_path,
          body(@join),
          "techtree"
        )

      assert deliver(ctx, "POST", @join_path, request).status == 401
      assert_receive {:broker_payload, payload}
      assert reason(ctx, payload) == :receipt_binding_mismatch
    end

    # The window is the library's default, 300 seconds either side, which is also
    # siwa-server's (SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS unset). The offsets
    # leave a minute and more of slack for a slow machine.
    for {label, created, expires, refusal} <- [
          {"signed more than five minutes ago", -400, nil, :request_too_old},
          {"dated more than five minutes ahead", 400, nil, :request_not_yet_valid},
          {"past the expiry it signed, inside the window", -200, -80, :request_expired}
        ] do
      test "OD-SIWA-CLOCK: a request #{label} is refused", ctx do
        window = window(unquote(created), unquote(expires))
        request = sign_with_window(ctx, "POST", @join_path, body(@join), window)

        assert deliver(ctx, "POST", @join_path, request).status == 401
        assert_receive {:broker_payload, payload}
        assert reason(ctx, payload) == unquote(refusal)
      end
    end
  end

  describe "Privy sign-in takes only this app's tokens, signed by Privy's key (OD-PRIVY)" do
    setup do
      owner =
        Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
          shared: true,
          isolation: "REPEATABLE READ"
        )

      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      key = JOSE.JWK.generate_key({:ec, "P-256"})
      {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()

      previous =
        {Application.get_env(:keyfleet, :privy), Application.get_env(:keyfleet, :privy_verifier)}

      Application.put_env(
        :keyfleet,
        :privy,
        Keyword.put(Application.fetch_env!(:keyfleet, :privy), :verification_key, public)
      )

      Application.put_env(:keyfleet, :privy_verifier, RegentPrivy.Session)

      on_exit(fn ->
        {privy, verifier} = previous
        Application.put_env(:keyfleet, :privy, privy)
        Application.put_env(:keyfleet, :privy_verifier, verifier)
      end)

      # The controller names each refusal's stage and reason only in telemetry.
      handler = "outside-deps-privy-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:keyfleet, :privy, :session_refused],
        fn _event, _measurements, meta, _config ->
          send(parent, {:privy_refused, meta.stage, meta.reason})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, key: key, public: public, did: "did:privy:outside-deps-" <> Ecto.UUID.generate()}
    end

    test "OD-PRIVY-CONTROL: a pair Privy signed for this app signs in", c do
      response = exchange(es256(c.key, access(c.did)), identity(c.key, c.did))

      assert json_response(response, 200)["authenticated"]
      assert {:ok, %{}} = Accounts.get_by_privy_did(c.did, actor: %SystemActor{})
    end

    test "OD-PRIVY-AUD: a token for another Privy app is refused", c do
      access = es256(c.key, access(c.did, %{"aud" => "another-app"}))

      exchange(access, identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :invalid_audience)
    end

    test "OD-PRIVY-ISS: a token from an issuer other than Privy is refused", c do
      access = es256(c.key, access(c.did, %{"iss" => "privy.example"}))

      exchange(access, identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :invalid_issuer)
    end

    test "OD-PRIVY-EXP: an expired token is refused", c do
      access = es256(c.key, access(c.did, %{"exp" => now() - 1}))

      exchange(access, identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :token_expired)
    end

    test "OD-PRIVY-NBF: a token that is not valid yet is refused", c do
      access = es256(c.key, access(c.did, %{"nbf" => now() + 300}))

      exchange(access, identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :token_not_yet_valid)
    end

    test "OD-PRIVY-ALG-NONE: an unsigned token is refused", c do
      exchange(unsigned(access(c.did)), identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :token_verification_failed)
    end

    # The classic key confusion: the public verification key, which anyone can
    # read, used as an HMAC secret.
    test "OD-PRIVY-ALG-HS256: a token signed with HS256 under the public key is refused", c do
      access = hs256(c.public, access(c.did))

      exchange(access, identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :token_verification_failed)
    end

    test "OD-PRIVY-FORGED: a token signed by any other ES256 key is refused", c do
      forger = JOSE.JWK.generate_key({:ec, "P-256"})

      exchange(es256(forger, access(c.did)), identity(c.key, c.did))
      |> assert_no_session(c.did, :access_verification, :token_verification_failed)
    end

    test "OD-PRIVY-PAIR: another person's identity token does not ride a valid access token", c do
      someone = "did:privy:outside-deps-" <> Ecto.UUID.generate()

      exchange(es256(c.key, access(c.did)), identity(c.key, someone))
      |> assert_no_session(c.did, :pair_binding, :subject_mismatch)

      assert {:ok, nil} = Accounts.get_by_privy_did(someone, actor: %SystemActor{})
    end
  end

  describe "Credits debits never spend the same Credit twice (OD-CREDITS)" do
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      admin!()
    end

    # The shared sandbox gives every caller the test's one connection, so the
    # two callers take turns (`Keyfleet.SandboxRace`). What this proves is that
    # whichever goes second reads the balance after the first one's debit; the
    # test below proves the row lock between separate connections.
    test "OD-CREDITS-LAST: two holds racing for the last Credit place one and refuse the other",
         c do
      person = fund!(c.admin, "1")

      results =
        SandboxRace.race_each([
          fn -> hold(person, "last-a", "1") end,
          fn -> hold(person, "last-b", "1") end
        ])

      assert [{:ok, %RegentCredits.Hold{}}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [refused] = Enum.reject(results, &match?({:ok, _}, &1))
      assert not_enough?(refused)

      assert_balance(person, available: "0", held: "1")
    end

    test "OD-CREDITS-KEY: the same hold sent twice at once is placed once", c do
      person = fund!(c.admin, "1")

      assert [{:ok, first}, {:ok, second}] =
               SandboxRace.race(fn -> hold(person, "same-key", "1") end, 2)

      assert first.id == second.id
      assert_balance(person, available: "0", held: "1")
    end
  end

  describe "Credits debits on separate connections (OD-CREDITS-LOCK)" do
    # Each caller has its own connection and transaction here, so the holds
    # really wait on each other's row lock; eight callers and the test itself
    # fit the test pool of ten connections. Their rows are committed to the test
    # database and stay there, under people no other test names, because the
    # ledger refuses to delete a transfer. Run it with --include external.
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual) end)
      admin!()
    end

    @tag :external
    test "OD-CREDITS-LOCK: eight holds of 1 racing over 3 Credits place exactly three", c do
      person = fund!(c.admin, "3")

      results =
        1..8
        |> Task.async_stream(&hold(person, "lock-#{&1}", "1"),
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3

      assert results |> Enum.reject(&match?({:ok, _}, &1)) |> Enum.all?(&not_enough?/1)

      assert_balance(person, available: "0", held: "3")
    end
  end

  # -- agent sign-in --

  defp body(map), do: Jason.encode!(map)

  # Sends a request already signed, as it was signed or at another address.
  defp deliver(ctx, method, path, request) do
    Req.request!(
      method: method |> String.downcase() |> String.to_existing_atom(),
      url: ctx.app <> path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  # Why the library refuses the request the site sent the sign-in server, with
  # the options the local sign-in server and siwa-server verify under.
  defp reason(ctx, payload) do
    assert {:error, reason} =
             Siwa.verify_authenticated_request(payload,
               secret: ctx.secret,
               audience: "keyfleet",
               wallet_audiences: ["keyfleet"]
             )

    reason
  end

  # The agent's own key signs the request again, over every covered component
  # but `component`: a genuine signature that simply does not cover it.
  defp sign_again_without(request, component, signer) do
    input_header = Siwa.Contract.signature_input_header()
    input = String.replace(request.headers[input_header], ~s("#{component}" ), "")
    refute input =~ ~s("#{component}")
    headers = Map.put(request.headers, input_header, input)

    {:ok, message} = Siwa.RequestAuth.signing_message(%{request | headers: headers})
    {:ok, "0x" <> hex} = Siwa.LocalSigner.sign_message(signer, message)
    encoded = hex |> Base.decode16!(case: :mixed) |> Base.encode64()
    signature = "#{Siwa.Contract.label()}=:#{encoded}:"

    %{request | headers: Map.put(headers, Siwa.Contract.signature_header(), signature)}
  end

  defp window(created, nil), do: [created_at: DateTime.add(DateTime.utc_now(), created)]

  defp window(created, expires),
    do: [created_at: DateTime.add(DateTime.utc_now(), created), expires_at: now() + expires]

  # `SignedAgentHelpers.sign/7` with the signature's own created and expiry
  # times chosen; the receipt itself is fresh.
  defp sign_with_window(ctx, method, path, body, window) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => ctx.signer.address,
          "chain_id" => 8453,
          "aud" => "keyfleet",
          "key_id" => ctx.signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: ctx.secret
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
        ctx.signer,
        [secret: ctx.secret, audience: "keyfleet", wallet_audiences: ["keyfleet"]] ++ window
      )

    request
  end

  # -- Privy --

  defp now, do: System.system_time(:second)

  defp access(did, changes \\ %{}) do
    Map.merge(
      %{
        "iss" => "privy.io",
        "aud" => Application.fetch_env!(:keyfleet, :privy)[:app_id],
        "sub" => did,
        "sid" => "session-" <> did,
        "iat" => now() - 1,
        "exp" => now() + 600
      },
      changes
    )
  end

  defp identity(key, did) do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    wallets = [%{type: "wallet", chain_type: "ethereum", address: wallet, lv: now() - 5}]
    es256(key, Map.put(access(did), "linked_accounts", Jason.encode!(wallets)))
  end

  defp es256(key, claims) do
    {_, token} = key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()
    token
  end

  defp hs256(secret, claims) do
    {_, token} =
      secret
      |> JOSE.JWK.from_oct()
      |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp unsigned(claims) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    header <> "." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> "."
  end

  defp exchange(access, identity) do
    build_conn()
    |> init_test_session(%{})
    |> put_valid_csrf()
    |> put_req_header("authorization", "Bearer " <> access)
    |> put_req_header("privy-id-token", identity)
    |> post("/auth/privy/session", %{})
  end

  defp put_valid_csrf(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end

  defp assert_no_session(response, did, stage, reason) do
    assert json_response(response, 401)["error"]["code"] == "unauthorized"
    assert_receive {:privy_refused, ^stage, ^reason}
    assert {:ok, nil} = Accounts.get_by_privy_did(did, actor: %SystemActor{})
  end

  # -- Credits --

  # A Credits admin for this test alone, who funds each person with a gift.
  defp admin! do
    admin = "did:privy:outside-deps-admin"
    admins = Application.get_env(:regent_credits, :admins)
    Application.put_env(:regent_credits, :admins, [admin])
    on_exit(fn -> Application.put_env(:regent_credits, :admins, admins) end)
    {:ok, admin: admin}
  end

  defp fund!(admin, amount) do
    person = "did:privy:outside-deps-" <> Ecto.UUID.generate()

    {:ok, [_gift]} =
      RegentCredits.give("outside-deps-#{Ecto.UUID.generate()}", [person], Decimal.new(amount),
        actor: Actor.admin(admin)
      )

    person
  end

  defp hold(person, key, amount) do
    RegentCredits.hold("#{key}-#{person}", person, Decimal.new(amount), "probe",
      actor: Actor.person(person, [], "keyfleet")
    )
  end

  defp not_enough?({:error, %Ash.Error.Invalid{errors: [%NotEnoughCredits{} | _]}}), do: true
  defp not_enough?(_result), do: false

  defp assert_balance(person, available: available, held: held) do
    balance = RegentCredits.balance(person)
    assert Decimal.eq?(balance.available, available), inspect(balance)
    assert Decimal.eq?(balance.held, held), inspect(balance)
    refute Enum.any?([balance.given, balance.purchased, balance.held], &Decimal.negative?/1)
  end
end
