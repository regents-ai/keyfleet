defmodule KeyfleetWeb.Plugs.McpAgent do
  @moduledoc """
  Admits a request to the Claude connector's MCP address, `/mcp`, and says who
  is calling, before AshAi's router (`AshAi.Mcp.Router`) runs the tool. Cookies
  are never read. While the connector is off (`Keyfleet.OAuth.enabled?/0`) the
  address answers 404.

  In order, from the request line and headers alone, with no body read:

  - a query string is refused (`unsupported_query`);
  - only `POST /mcp` is served: another method is refused with 405, another
    address under it with 404;
  - a page from another site (any `Origin` but this site's own, `null`
    included) is refused (`origin_not_allowed`); a request with no `Origin`, as
    MCP clients send, goes on;
  - a body that is not JSON is refused (`unsupported_media_type`).

  Then who is calling, and only once that is proved is the body decoded:

  - A request with an `Authorization` header is a connected app's. Its token
    must be one this site gave for `/mcp` with the identity permission, as
    `RegentOAuth` checks it; any other, a made-up one included, is refused
    (`connection_required`, below) with its body unread. A token that verifies
    spends its account's budget: 120 requests a minute, after the endpoint's
    ceiling for the connector's addresses, and past it is refused with 429,
    its body unread. Only the token is read before the budget is spent, since
    the budget is the token's account's, so a request past it never reaches
    the sign-in server or the pairings. Then its body is read and decoded.
  - A request without one that carries a SIWA signature
    (`KeyfleetWeb.BodyReader.signed?/1`) has its body read first, since the
    signature covers those exact bytes, then its signature checked; only a
    request whose signature verifies has its body decoded.
  - A request with neither is refused (`connection_required`) with its body
    unread.

  A body is read whole, up to 759,808 bytes (742 KiB), and kept as it came
  (`KeyfleetWeb.BodyReader.read_signed/3`): a longer one is refused with 413
  (`request_entity_too_large`), and one that can't be read with 400
  (`bad_request`). Its call must be one JSON object: a JSON-RPC batch is
  refused (`batch_not_supported`), and anything else, an empty body included,
  with 400 (`bad_request`).

  While the app's own identity is paired with that same account and the
  person allowed Keyfleet's agent permission (`Keyfleet.OAuth.agent_scope/0`),
  the actor is that paired agent, as an agent signing its own requests would
  be (`KeyfleetWeb.Plugs.SignedAgent.actor_for/2`, with the token as its
  `connection`), so AshAi lists and runs the agent's tools under the same
  policies, and its identity tools besides. Its syncs wait for news under its
  account (`waiter` in the actions' context), since every person's Claude
  calls from the same servers. Its pairing is read again just
  before the answer leaves, and an answer whose pairing ended or changed hands
  meanwhile is replaced (`agent_not_paired`), so it never carries the former
  person's data. An identity paired with no one, or with someone else, leaves
  the app itself the actor (`Keyfleet.Actors.ConnectedApp`), which runs its
  identity tools only. With the agent permission it is still listed the
  paired agent's tools, so the list it keeps works once it pairs, and until
  then each answers `agent_not_paired` (`Keyfleet.Agents.Connection.Listing`).
  Each app has its own identity, so an app pairs only
  with a code its person gives it and never takes another app's pairing. The
  identity's wallet is read once per account and app
  (`Keyfleet.Agents.HostedAddress`), so a call seldom waits on the sign-in
  server; while that server or the pairings can't be read, the request is
  refused with that reason (`siwa_request_failed`, `pairing_unavailable`)
  rather than served as someone it may not be.

  A request without a token that an agent signed with its own SIWA key, as it
  signs its requests under `/api/v1/agent`, is that agent once its signature
  verifies, its call decodes and its pairing admits it, exactly as
  `KeyfleetWeb.Plugs.SignedAgent` admits a signed request: the same refusals,
  and the same tools the connector's paired agent gets, without the identity
  tools, which keep a connected app's hosted identity. Its syncs wait for news
  under its client address, as its signed syncs do, and its pairing is read
  again before the answer leaves, as the connector's is.

  A request with neither, or with a token this site didn't give, is refused
  (`connection_required`) with words for both callers: an app is asked to
  connect, an agent is told it may sign each call with its own key instead.
  The `WWW-Authenticate` challenge names this site's sign-in and both
  permissions, so an app such as Claude starts its sign-in on its first
  request.

  Each answer is private and never kept (`cache-control: private, no-store`).
  Refusals answer `{"error": {"code", "message", "hint"}}`, the site's one
  shape; what a tool itself refuses comes back as the tool's error, in the
  same shape (`KeyfleetWeb.ToolErrors`).
  """

  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias Keyfleet.Actors.{Agent, ConnectedApp, Human}
  alias Keyfleet.Agents.HostedAddress
  alias KeyfleetWeb.ClientAddress
  alias KeyfleetWeb.Plugs.SignedAgent
  alias KeyfleetWeb.PublicDocuments

  # The largest call is a picture's upload: 512 KiB as base64 is 699,052
  # bytes, which the picture tool also takes broken into lines, skipping the
  # breaks. In lines of 64, the shortest an encoder writes (PEM; MIME writes
  # 76), that is 10,923 lines, each ending in a CRLF that JSON writes as
  # `\r\n`, four bytes: 699,052 + 43,692 = 742,744. 742 KiB leaves 17,064
  # for the rest of the call.
  @body_limit 742 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    cond do
      not Keyfleet.OAuth.enabled?() ->
        refuse(conn, "not_found")

      conn.query_string != "" ->
        refuse(conn, "unsupported_query")

      conn.path_info != ["mcp"] ->
        refuse(conn, "not_found")

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> refuse("method_not_allowed")

      not own_origin?(conn) ->
        refuse(conn, "origin_not_allowed")

      not json?(conn) ->
        refuse(conn, "unsupported_media_type")

      true ->
        caller(conn)
    end
  end

  @doc false
  def account(conn), do: conn.private.mcp_principal.subject

  defp own_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin == PublicDocuments.url("")
      _several -> false
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "json", _params}, Plug.Conn.Utils.content_type(type))
      _none_or_several -> false
    end
  end

  # A token makes the request a connected app's; without one, a signature
  # makes it the agent's own.
  defp caller(conn) do
    cond do
      get_req_header(conn, "authorization") != [] -> connected_app(conn)
      KeyfleetWeb.BodyReader.signed?(conn) -> signed_agent(conn)
      true -> connect(conn)
    end
  end

  @doc """
  The token of the request's one `Authorization` header when its scheme is
  Bearer, its name in any case (RFC 9110 §11.1), or `nil`.
  """
  def bearer(conn) do
    with [credentials] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(credentials, " ", parts: 2),
         "bearer" <- String.downcase(scheme, :ascii) do
      token
    else
      _no_bearer -> nil
    end
  end

  defp connected_app(conn) do
    with bearer when is_binary(bearer) <- bearer(conn),
         {:ok, principal} <-
           RegentOAuth.verify(bearer, RegentOAuth.resource(), RegentMCPAgents.identity_scope()) do
      conn
      |> put_private(:mcp_principal, principal)
      |> RegentAgentAccess.RateLimit.call(budget())
      |> take_call()
      |> as_connected_app(principal)
    else
      _no_token_of_ours -> connect(conn)
    end
  end

  # A connected app's call, read and decoded once its token verified and its
  # account's budget let it in.
  defp take_call(%{halted: true} = conn), do: conn

  defp take_call(conn) do
    with {:ok, conn} <- read_call(conn),
         {:ok, conn} <- decode_call(conn) do
      conn
    else
      {:error, conn, code} -> refuse(conn, code)
    end
  end

  # The agent the signature names, admitted as a signed request is, once the
  # bytes it signed are read.
  defp signed_agent(conn) do
    case read_call(conn) do
      {:ok, conn} ->
        Siwa.AgentAuthPlug.call(conn,
          client: Keyfleet.SiwaBroker,
          hooks: __MODULE__,
          audience: "keyfleet"
        )

      {:error, conn, code} ->
        refuse(conn, code)
    end
  end

  # The body whole, kept as it came, by the reader a signature needs.
  defp read_call(conn) do
    case KeyfleetWeb.BodyReader.read_signed(conn, [], @body_limit) do
      {:ok, _body, conn} -> {:ok, conn}
      {:more, _partial, conn} -> {:error, conn, "request_entity_too_large"}
      {:error, _reason} -> {:error, conn, "bad_request"}
    end
  end

  defp decode_call(%{assigns: %{raw_body: body}} = conn) do
    case Jason.decode(body) do
      {:ok, call} when is_map(call) -> {:ok, %{conn | body_params: call, params: call}}
      {:ok, batch} when is_list(batch) -> {:error, conn, "batch_not_supported"}
      _not_one_call -> {:error, conn, "bad_request"}
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(_conn, _headers), do: {:ok, nil}

  # The signature verified: the call is decoded, then the agent admitted.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context) do
    with {:ok, conn} <- decode_call(conn),
         {:ok, %{assigns: %{agent_actor: agent}} = conn} <- SignedAgent.accept_agent(conn, data) do
      {:ok,
       conn
       |> Ash.PlugHelpers.set_actor(agent)
       |> Ash.PlugHelpers.set_context(%{waiter: ClientAddress.key(conn)})
       |> register_before_send(&recheck(&1, agent))}
    else
      {:error, _conn, code} -> {:error, %{refusal: code}}
      {:error, _metadata} = refused -> refused
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{refusal: code}), do: refuse(conn, code)

  def deny(conn, metadata) do
    {status, body} = SignedAgent.refusal(conn, metadata)
    conn |> put_status(status) |> Phoenix.Controller.json(body) |> halt()
  end

  # The app's paired identity, when the person allowed it to work here as that
  # agent; the app itself otherwise. Only the token's own account chooses the
  # identity, and only a pairing with that same account, whose person is
  # here, counts.
  defp as_connected_app(%{halted: true} = conn, _principal), do: conn

  defp as_connected_app(conn, principal) do
    if Keyfleet.OAuth.agent_scope() in principal.scopes,
      do: as_agent(conn, principal),
      else: Ash.PlugHelpers.set_actor(conn, %ConnectedApp{principal: principal})
  end

  defp as_agent(conn, %{subject: subject} = principal) do
    case hosted_agent(principal) do
      {:ok, %Agent{privy_user_id: ^subject, pairing: %Human{}} = agent} ->
        conn
        |> Ash.PlugHelpers.set_actor(agent)
        |> Ash.PlugHelpers.set_context(%{waiter: {:mcp, subject}})
        |> register_before_send(&recheck(&1, agent))

      # Paired with no one, with someone else, or with a person not here yet.
      {:ok, _not_this_persons} ->
        Ash.PlugHelpers.set_actor(conn, %ConnectedApp{principal: principal})

      {:error, code} ->
        refuse(conn, code)
    end
  end

  defp hosted_agent(principal) do
    case HostedAddress.fetch(principal) do
      {:ok, address} -> paired(address, principal)
      {:error, _refused} -> {:error, "siwa_request_failed"}
    end
  end

  defp paired(address, principal) do
    case SignedAgent.actor_for(address, principal) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_paired} -> {:ok, :not_paired}
      {:error, _unread} -> {:error, "pairing_unavailable"}
    end
  end

  # The tool ran after the pairing was read. Before its answer leaves, the
  # identity's pairing must still be this one, with the same person;
  # otherwise the answer is replaced. A stream, which has already begun, is
  # left as it is.
  defp recheck(%{state: :set} = conn, %Agent{} = agent) do
    case RegentAgents.Authority.resolve(Keyfleet.Repo, agent.wallet_address) do
      {:ok, %{id: id, privy_user_id: person}}
      when id == agent.pairing_id and person == agent.privy_user_id ->
        conn

      {:ok, _other_pairing} ->
        replace(conn, "agent_not_paired")

      {:error, :not_paired} ->
        replace(conn, "agent_not_paired")

      {:error, _unread} when conn.status in 200..299 ->
        replace(conn, "pairing_unavailable")

      {:error, _unread} ->
        conn
    end
  end

  defp recheck(conn, _agent), do: conn

  defp replace(conn, code) do
    {status, message, hint} = words(code)

    %{
      conn
      | status: status,
        resp_body: Jason.encode_to_iodata!(%{error: %{code: code, message: message, hint: hint}})
    }
    |> put_resp_content_type("application/json")
  end

  defp connect(conn) do
    conn
    |> put_resp_header(
      "www-authenticate",
      RegentOAuth.challenge(Enum.join(RegentOAuth.scopes(), " "))
    )
    |> refuse("connection_required")
  end

  defp refuse(conn, code) do
    {status, message, hint} = words(code)

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: %{code: code, message: message, hint: hint}})
    |> halt()
  end

  defp words("not_found"),
    do: {404, "There is nothing at this address.", "Keyfleet's connector is at #{url()} alone."}

  defp words("unsupported_query"),
    do:
      {400, "The connector's address takes no query string.",
       "Send the same request to #{url()} with nothing after it."}

  defp words("method_not_allowed"),
    do:
      {405, "The connector's address takes POST only.",
       "Send each JSON-RPC call as a POST to #{url()}."}

  defp words("origin_not_allowed"),
    do:
      {403, "A page on another site can't call this address.",
       "Call it from your app, not from a web page on another site."}

  defp words("unsupported_media_type"),
    do:
      {415, "The connector's address takes a JSON body only.",
       "Send one JSON-RPC call with Content-Type: application/json."}

  defp words("batch_not_supported"),
    do: {400, "Send one call a request.", "Send each call in its own request."}

  defp words("request_entity_too_large"),
    do:
      {413, "The connector's address takes a call of at most #{@body_limit} bytes.",
       "Send a shorter call. A picture of up to 512 KB fits in one."}

  defp words("bad_request"),
    do:
      {400, "The body isn't one JSON-RPC call.",
       "Send one JSON-RPC call as a JSON object with Content-Type: application/json."}

  defp words("siwa_request_failed"), do: site_words(503, "siwa_request_failed")
  defp words("pairing_unavailable"), do: site_words(503, "pairing_unavailable")
  defp words("agent_not_paired"), do: site_words(403, "agent_not_paired")

  # One refusal for both callers: an app that has not connected yet, and an
  # agent that sent its call unsigned.
  defp words("connection_required"),
    do:
      {401, "Connect Keyfleet, or sign this request with your own agent key.",
       "An app: add #{url()} to its connectors, such as Claude's or ChatGPT's, then sign in to Keyfleet and allow it. " <>
         "An agent with its own key needs no connector: sign each call as " <>
         PublicDocuments.url("/skill.md") <> " says under Pairing and Requests."}

  # The words the site's signed requests give the same refusal.
  defp site_words(status, code) do
    %{error: %{message: message, hint: hint}} = KeyfleetWeb.Refusal.body(code)
    {status, message, hint}
  end

  defp url, do: PublicDocuments.url("/mcp")

  # 120 requests a minute for each connected account, after the endpoint's
  # ceiling for the connector's addresses. Read on each request, as the
  # endpoint's budgets are.
  defp budget do
    budget = Application.fetch_env!(:keyfleet, :mcp_rate_limit)

    RegentAgentAccess.RateLimit.init(
      policy: "mcp",
      limit: Keyword.fetch!(budget, :limit),
      window: Keyword.fetch!(budget, :window_seconds),
      admit: &Keyfleet.Accounts.RequestRateLimiter.admit/3,
      key: &__MODULE__.account/1
    )
  end
end
