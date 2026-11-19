defmodule KeyfleetWeb.OAuthConsentTest do
  # Connecting an app to Keyfleet with the connector switched on, as a person's
  # browser does it: their signed-in session opens the consent page, the page's
  # own form posts Allow or Cancel with the cookie the page set, and the app
  # trades the code at the token address.
  # - ChatGPT's published identity, exactly as chatgpt.com serves it, signs its
  #   token requests with its own key: a request without its assertion, or with
  #   one by another key, for another audience or used before, is refused, and
  #   its code still works after;
  # - its long `state` comes back whole, and the longest request consent takes
  #   still fits the session cookie;
  # - Allow and Cancel answer a page that sends the browser on to the app's
  #   callback on the app's own host, and the site's form-action stays 'self';
  # - Claude's published identity and an app registered here connect as before.
  # Published identities and key sets are served without a network, and the
  # hosted signer is a stand-in; the rest is the site's.
  use KeyfleetWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Keyfleet.Accounts

  @chatgpt "https://chatgpt.com/oauth/client.json"
  @chatgpt_keys "https://chatgpt.com/oauth/jwks.json"
  @chatgpt_callback "https://chatgpt.com/connector_platform_oauth_redirect"
  @claude "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_callback "https://claude.ai/api/mcp/auth_callback"
  @scopes "regent.identity.manage keyfleet.agent"
  @jwt_bearer "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @verifier String.duplicate("v", 43)
  @site_key String.duplicate("k", 32)

  defmodule Published do
    @moduledoc false
    # ChatGPT's published identity as chatgpt.com served it on 19 Nov 2026, the
    # key set beside it, holding the test's key, and Claude's published
    # identity. Each read reaches the test.
    def request(:get, url, _opts) do
      {test, keys} = Application.fetch_env!(:keyfleet, __MODULE__)
      send(test, {:read, url})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body(url, keys))
       }}
    end

    defp body("https://chatgpt.com/oauth/client.json", _keys),
      do: %{
        "client_id" => "https://chatgpt.com/oauth/client.json",
        "client_uri" => "https://chatgpt.com/",
        "redirect_uris" => ["https://chatgpt.com/connector_platform_oauth_redirect"],
        "token_endpoint_auth_method" => "private_key_jwt",
        "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
        "grant_types" => [
          "authorization_code",
          "refresh_token",
          "urn:ietf:params:oauth:grant-type:jwt-bearer"
        ],
        "response_types" => ["code"],
        "client_name" => "ChatGPT",
        "logo_uri" => "https://persistent.oaistatic.com/sonic/misc/openai-logo.png",
        "token_endpoint_auth_signing_alg" => "RS256",
        "jwks_uri" => "https://chatgpt.com/oauth/jwks.json"
      }

    defp body("https://chatgpt.com/oauth/jwks.json", keys), do: %{"keys" => keys}

    defp body("https://claude.ai/oauth/mcp-oauth-client-metadata", _keys),
      do: %{
        "client_id" => "https://claude.ai/oauth/mcp-oauth-client-metadata",
        "client_name" => "Claude",
        "client_uri" => "https://claude.ai",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      }
  end

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), foreign: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    connector_on()

    # Kept key sets and client rows live in Boruta's cache, which outlives each
    # test's rolled-back rows.
    {:ok, _} = Boruta.Config.cache_backend().delete_all()

    {_, public} = JOSE.JWK.to_public_map(key)
    public = Map.merge(public, %{"kid" => "chatgpt-1", "alg" => "RS256", "use" => "sig"})
    put_env(:regent_http, :public_client, __MODULE__.Published)
    put_env(:keyfleet, __MODULE__.Published, {self(), [public]})

    from = {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}
    %{from: from, browser: signed_in(from)}
  end

  test "ChatGPT connects by its published identity, signing its code exchange and its refresh with its own key",
       c do
    state = long_state(600)
    page = consent(c.browser, query(@chatgpt, @chatgpt_callback, state, %{"ui_locales" => "en"}))

    # Consent reads the document only; the key set is read at the token address.
    assert_received {:read, @chatgpt}
    refute_received {:read, @chatgpt_keys}
    assert form_action(page) == "form-action 'self'"

    {returning, address} = decide(page, "allow")
    assert form_action(returning) == "form-action 'self'"
    assert String.starts_with?(address, @chatgpt_callback <> "?")
    assert %{"code" => code, "state" => ^state} = answered(address)

    grant = %{
      "grant_type" => "authorization_code",
      "client_id" => @chatgpt,
      "code" => code,
      "code_verifier" => @verifier,
      "redirect_uri" => @chatgpt_callback,
      "resource" => RegentOAuth.resource()
    }

    # Without its assertion, or with one by another key or for another
    # audience, ChatGPT is refused, and its code still works after.
    for refused <- [
          grant,
          Map.merge(grant, assertion(c.foreign, RegentOAuth.issuer())),
          Map.merge(grant, assertion(c.key, "https://elsewhere.example"))
        ] do
      assert {401, %{"error" => "invalid_client"}} = token(refused, c.from)
    end

    signed = assertion(c.key, RegentOAuth.issuer())

    assert {200, %{"access_token" => access, "refresh_token" => refresh_token}} =
             token(Map.merge(grant, signed), c.from)

    assert "register_identity" in tool_names(access, c.from)

    # A refresh names ChatGPT by its assertion alone. Each assertion is used
    # once: the one its code exchange spent is refused.
    refresh = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "resource" => RegentOAuth.resource()
    }

    assert {401, %{"error" => "invalid_client"}} = token(Map.merge(refresh, signed), c.from)

    assert {200, %{"access_token" => _}} =
             token(Map.merge(refresh, assertion(c.key, RegentOAuth.token_endpoint())), c.from)

    assert_received {:read, @chatgpt_keys}
    refute_received {:read, @chatgpt}
  end

  test "Cancel sends the browser back to ChatGPT declined, with its long state whole", c do
    state = long_state(600)

    {returning, address} =
      c.browser
      |> consent(query(@chatgpt, @chatgpt_callback, state, %{"ui_locales" => "en"}))
      |> decide("deny")

    assert form_action(returning) == "form-action 'self'"
    assert String.starts_with?(address, @chatgpt_callback <> "?")
    assert %{"error" => "access_denied", "state" => ^state} = answered = answered(address)
    refute Map.has_key?(answered, "code")
  end

  test "the longest request consent takes fits the person's session and connects; one longer is refused",
       c do
    # The request's parameters, as consent counts them, come to 2,048 bytes.
    filler = %{"ui_locales" => "en"}
    room = 2048 - byte_size(Jason.encode!(params(@chatgpt, @chatgpt_callback, "", filler)))
    state = long_state(room)

    {_returning, address} =
      c.browser
      |> consent(query(@chatgpt, @chatgpt_callback, state, filler))
      |> decide("allow")

    assert %{"code" => _, "state" => ^state} = answered(address)

    refused = consent(c.browser, query(@chatgpt, @chatgpt_callback, state <> "s", filler))
    assert refused.status == 400
    assert %{"error" => "invalid_request"} = Jason.decode!(refused.resp_body)
  end

  test "Claude connects by its published identity with no key of its own, as before", c do
    {_returning, address} =
      c.browser
      |> consent(query(@claude, @claude_callback, "claude-state"))
      |> decide("allow")

    assert_received {:read, @claude}
    assert %{"code" => code, "state" => "claude-state"} = answered(address)

    assert {200, %{"access_token" => access, "refresh_token" => refresh_token}} =
             token(
               %{
                 "grant_type" => "authorization_code",
                 "client_id" => @claude,
                 "code" => code,
                 "code_verifier" => @verifier,
                 "redirect_uri" => @claude_callback,
                 "resource" => RegentOAuth.resource()
               },
               c.from
             )

    assert "register_identity" in tool_names(access, c.from)

    assert {200, %{"access_token" => _}} =
             token(
               %{
                 "grant_type" => "refresh_token",
                 "client_id" => @claude,
                 "refresh_token" => refresh_token,
                 "resource" => RegentOAuth.resource()
               },
               c.from
             )

    # Only consent reads the address; the token address uses the record.
    refute_received {:read, @claude}
  end

  test "an app registered here connects with no key of its own, as before", c do
    callback = "https://agent.example/oauth/callback"

    registered =
      build_conn()
      |> Map.put(:remote_ip, c.from)
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/oauth/register",
        Jason.encode!(%{"client_name" => "Research Agent", "redirect_uris" => [callback]})
      )

    assert registered.status == 201
    client_id = Jason.decode!(registered.resp_body)["client_id"]

    {_returning, address} =
      c.browser
      |> consent(query(client_id, callback, "registered-state"))
      |> decide("allow")

    assert String.starts_with?(address, callback <> "?")
    assert %{"code" => code, "state" => "registered-state"} = answered(address)

    assert {200, %{"access_token" => access}} =
             token(
               %{
                 "grant_type" => "authorization_code",
                 "client_id" => client_id,
                 "code" => code,
                 "code_verifier" => @verifier,
                 "redirect_uri" => callback,
                 "resource" => RegentOAuth.resource()
               },
               c.from
             )

    assert "register_identity" in tool_names(access, c.from)
  end

  # A person signed in on Keyfleet with their wallet: the browser that opens
  # consent, from `from`.
  defp signed_in(from) do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    account =
      Accounts.register_verified!("did:privy:consent-" <> wallet, wallet, [wallet],
        actor: %Keyfleet.Actors.System{}
      )

    build_conn()
    |> init_test_session(%{human_account_id: account.id})
    |> Map.put(:remote_ip, from)
  end

  # The consent page the app's `query` opens in `browser`.
  defp consent(browser, query),
    do: browser |> put_req_header("accept", "text/html") |> get("/oauth/authorize?" <> query)

  # The person presses `decision` ("allow" or "deny") on the consent `page`: its
  # own form, posted as a browser posts it with the cookie the page set. Answers
  # the page that returns them to the app, and the address it returns to.
  defp decide(page, decision) do
    assert page.status == 200
    form = LazyHTML.from_document(page.resp_body)

    fields = %{
      "_csrf_token" => field(form, "_csrf_token"),
      "approval_key" => field(form, "approval_key"),
      "decision" => decision
    }

    returning =
      page
      |> recycle()
      |> Map.put(:remote_ip, page.remote_ip)
      |> put_req_header("accept", "text/html")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/oauth/authorize", URI.encode_query(fields))

    {returning, return_address(returning)}
  end

  defp field(form, name) do
    [value] = form |> LazyHTML.query("input[name='#{name}']") |> LazyHTML.attribute("value")
    value
  end

  # The address the page Allow or Cancel answers sends the browser on to: its
  # refresh, which its Continue link names too. The answer is never a redirect.
  defp return_address(returning) do
    assert returning.status == 200
    assert get_resp_header(returning, "location") == []
    page = LazyHTML.from_document(returning.resp_body)

    ["0;url=" <> address] =
      page |> LazyHTML.query("meta[http-equiv='refresh']") |> LazyHTML.attribute("content")

    assert address in (page |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
    address
  end

  # What the app's callback receives.
  defp answered(address), do: URI.decode_query(URI.parse(address).query)

  # The forms one page may post to, from its content security policy.
  defp form_action(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")

    policy
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, "form-action "))
  end

  defp query(client_id, callback, state, extra \\ %{}),
    do: URI.encode_query(params(client_id, callback, state, extra))

  # An authorization request asking for every permission the site has, as an
  # app sends it.
  defp params(client_id, callback, state, extra) do
    Map.merge(
      %{
        "client_id" => client_id,
        "redirect_uri" => callback,
        "response_type" => "code",
        "scope" => @scopes,
        "state" => state,
        "resource" => RegentOAuth.resource(),
        "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
        "code_challenge_method" => "S256"
      },
      extra
    )
  end

  # A state of `length` URL-safe characters, as an app makes one.
  defp long_state(length),
    do:
      :crypto.strong_rand_bytes(length)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, length)

  # ChatGPT's assertion for `aud`, signed by `key` under the key id its key set
  # names, used once.
  defp assertion(key, aud) do
    now = System.system_time(:second)

    claims = %{
      "iss" => @chatgpt,
      "sub" => @chatgpt,
      "aud" => aud,
      "iat" => now,
      "exp" => now + 300,
      "jti" => Ecto.UUID.generate()
    }

    {_, compact} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "chatgpt-1"}, claims)
      |> JOSE.JWS.compact()

    %{"client_assertion_type" => @jwt_bearer, "client_assertion" => compact}
  end

  # A token request, as a form, the way OAuth sends one.
  defp token(params, from) do
    answer =
      build_conn()
      |> Map.put(:remote_ip, from)
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/oauth/token", URI.encode_query(params))

    {answer.status, Jason.decode!(answer.resp_body)}
  end

  # The tools /mcp lists for an app's access token.
  defp tool_names(access, from) do
    listed =
      build_conn()
      |> Map.put(:remote_ip, from)
      |> put_req_header("authorization", "Bearer " <> access)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post(
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})
      )

    for tool <- Jason.decode!(listed.resp_body)["result"]["tools"], do: tool["name"]
  end

  # Switches the connector on for one test, as config/runtime.exs does with
  # KEYFLEET_CLAUDE_CONNECTOR_ENABLED=true; its sign-in keeps its rows in this
  # test's transaction, and everything is put back after. The hosted signer
  # gives each app's identity a wallet of its own.
  defp connector_on do
    origin = "http://127.0.0.1:4002"

    put_env(
      :keyfleet,
      Keyfleet.OAuth,
      Keyword.merge(Application.fetch_env!(:keyfleet, Keyfleet.OAuth),
        enabled?: true,
        issuer: origin,
        resource: origin <> "/mcp"
      )
    )

    put_env(
      :regent_mcp_agents,
      :config,
      Keyword.merge(Application.fetch_env!(:regent_mcp_agents, :config),
        enabled?: true,
        hosted_signer: [base_url: "https://siwa.test", key: @site_key]
      )
    )

    put_env(:regent_agents, :hosted_pairing, [:claude])
    put_env(:regent_mcp_agents, :req_options, plug: {Req.Test, RegentMCPAgents.HostedSigner})
    keep_env(:regent_oauth, :site)
    keep_env(:boruta, Boruta.Oauth)

    :ok = RegentOAuth.configure(Keyfleet.OAuth)
    :ok = RegentMCPAgents.configure!()

    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      key = Jason.decode!(body)["identity_key"]
      Req.Test.json(conn, %{"address" => "0x" <> binary_part(key, 0, 40)})
    end)
  end

  defp put_env(app, key, value) do
    keep_env(app, key)
    Application.put_env(app, key, value)
  end

  defp keep_env(app, key) do
    old = Application.fetch_env(app, key)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
