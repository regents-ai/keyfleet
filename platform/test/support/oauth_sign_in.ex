defmodule KeyfleetWeb.OAuthSignIn do
  @moduledoc """
  The connector's sign-in as a person's browser and an app go through it, for
  tests with the connector on: ChatGPT's and Claude's published identities
  served without a network, the consent page opened in a signed-in session,
  Allow or Cancel pressed on the page's own form with the cookie the page set,
  and a code traded at the token address, ChatGPT's signed with its own key.
  """
  import ExUnit.Assertions
  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Plug.Conn
  import KeyfleetWeb.SessionAuthorityHelpers, only: [build_conn: 0, init_test_session: 2]

  @endpoint KeyfleetWeb.Endpoint
  @chatgpt "https://chatgpt.com/oauth/client.json"
  @chatgpt_callback "https://chatgpt.com/connector_platform_oauth_redirect"
  @scopes "regent.identity.manage keyfleet.agent"
  @jwt_bearer "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @verifier String.duplicate("v", 43)

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

  @doc """
  Serves the published identities to the calling test until it ends, with
  `key` in ChatGPT's key set; each read reaches the test as `{:read, url}`.
  Kept key sets and client rows live in Boruta's cache, which outlives each
  test's rolled-back rows, so it starts empty.
  """
  def publish!(key) do
    {:ok, _} = Boruta.Config.cache_backend().delete_all()
    {_, public} = JOSE.JWK.to_public_map(key)
    public = Map.merge(public, %{"kid" => "chatgpt-1", "alg" => "RS256", "use" => "sig"})
    put_env(:regent_http, :public_client, Published)
    put_env(:keyfleet, Published, {self(), [public]})
  end

  @doc "The browser of the person signed in to `account`, from `from`."
  def browser(account, from) do
    build_conn()
    |> init_test_session(%{human_account_id: account.id})
    |> Map.put(:remote_ip, from)
  end

  @doc "The consent page the app's `query` opens in `browser`."
  def consent(browser, query),
    do: browser |> put_req_header("accept", "text/html") |> get("/oauth/authorize?" <> query)

  @doc """
  The person presses `decision` ("allow" or "deny") on the consent `page`: its
  own form, posted as a browser posts it with the cookie the page set. Answers
  the page that returns them to the app, and the address it returns to.
  """
  def decide(page, decision) do
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

  @doc "What the app's callback receives at `address`."
  def answered(address), do: URI.decode_query(URI.parse(address).query)

  @doc "An authorization request asking for every permission the site has, as a query."
  def query(client_id, callback, state, extra \\ %{}),
    do: URI.encode_query(params(client_id, callback, state, extra))

  @doc "An authorization request asking for every permission the site has, as an app sends it."
  def params(client_id, callback, state, extra) do
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

  @doc "The token request trading `code`, given to `client_id` for `callback`, with its verifier."
  def code_grant(client_id, code, callback),
    do: %{
      "grant_type" => "authorization_code",
      "client_id" => client_id,
      "code" => code,
      "code_verifier" => @verifier,
      "redirect_uri" => callback,
      "resource" => RegentOAuth.resource()
    }

  @doc "ChatGPT's assertion for `aud`, signed by `key` under the key id its key set names, used once."
  def assertion(key, aud) do
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

  @doc "A token request from `from`, as a form, the way OAuth sends one: its status and answer."
  def token(params, from) do
    answer =
      build_conn()
      |> Map.put(:remote_ip, from)
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/oauth/token", URI.encode_query(params))

    {answer.status, Jason.decode!(answer.resp_body)}
  end

  @doc """
  The access token ChatGPT holds once the person signed in to `account`
  allows it every permission from `from`, and it trades the code signed with
  `key`, the key `publish!/1` serves.
  """
  def chatgpt_access!(account, key, from) do
    {_returning, address} =
      account
      |> browser(from)
      |> consent(query(@chatgpt, @chatgpt_callback, "chatgpt-state"))
      |> decide("allow")

    %{"code" => code} = answered(address)

    grant =
      Map.merge(
        code_grant(@chatgpt, code, @chatgpt_callback),
        assertion(key, RegentOAuth.issuer())
      )

    assert {200, %{"access_token" => access}} = token(grant, from)
    access
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

  defp put_env(app, key, value) do
    old = Application.fetch_env(app, key)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end
end
