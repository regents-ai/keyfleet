defmodule KeyfleetWeb.Plugs.McpAgent do
  @moduledoc """
  Admits a request to the Claude connector's MCP address, `/mcp`, and says who
  is calling, before AshAi's router (`AshAi.Mcp.Router`) runs the tool. Cookies
  are never read. While the connector is off (`Keyfleet.OAuth.enabled?/0`) the
  address answers 404.

  In order, before the token is looked at:

  - a query string is refused (`unsupported_query`);
  - only `POST /mcp` is served: another method is refused with 405, another
    address under it with 404;
  - a page from another site (any `Origin` but this site's own, `null`
    included) is refused (`origin_not_allowed`); a request with no `Origin`, as
    MCP clients send, goes on;
  - a body that is not JSON is refused (`unsupported_media_type`), and so is a
    JSON-RPC batch (`batch_not_supported`).

  Then the request carries a connected app's token (`Authorization: Bearer`),
  one this site gave for `/mcp` with the identity permission, as `RegentOAuth`
  checks it, and spends its account's budget: 120 requests a minute, after the
  endpoint's ceiling for the connector's addresses. Only the token is read
  before the budget is spent, since the budget is the token's account's, so a
  request past it never reaches the sign-in server or the pairings.

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
  the app itself the actor (`Keyfleet.Actors.ConnectedApp`), with its
  identity tools only. The identity's wallet is read once per account
  (`Keyfleet.Agents.HostedAddress`), so a call seldom waits on the sign-in
  server; while that server or the pairings can't be read, the request is
  refused with that reason (`siwa_request_failed`, `pairing_unavailable`)
  rather than served as someone it may not be.

  A request without a token that an agent signed with its own SIWA key, as it
  signs its requests under `/api/v1/agent`, is that agent once its signature
  verifies and its pairing admits it, exactly as `KeyfleetWeb.Plugs.SignedAgent`
  admits a signed request: the same refusals, and the same tools the
  connector's paired agent gets, without the identity tools, which keep a
  connected app's hosted identity. The signature covers the exact bytes
  `KeyfleetWeb.BodyReader` kept. Its syncs wait for news under its client
  address, as its signed syncs do, and its pairing is read again before the
  answer leaves, as the connector's is.

  A request with neither, or with a token this site didn't give, is asked to
  connect (`connection_required`), with the `WWW-Authenticate` challenge
  naming this site's sign-in and both permissions, so an app such as Claude
  starts its sign-in on its first request.

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

      is_list(conn.body_params["_json"]) ->
        refuse(conn, "batch_not_supported")

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
      Siwa.AgentAuthPlug.signed_request?(conn) -> signed_agent(conn)
      true -> connect(conn)
    end
  end

  defp connected_app(conn) do
    with ["Bearer " <> bearer] <- get_req_header(conn, "authorization"),
         {:ok, principal} <-
           RegentOAuth.verify(bearer, RegentOAuth.resource(), RegentMCPAgents.identity_scope()) do
      conn
      |> put_private(:mcp_principal, principal)
      |> RegentAgentAccess.RateLimit.call(budget())
      |> as_connected_app(principal)
    else
      _no_token_of_ours -> connect(conn)
    end
  end

  # The agent the signature names, admitted as a signed request is.
  defp signed_agent(conn) do
    Siwa.AgentAuthPlug.call(conn,
      client: Keyfleet.SiwaBroker,
      hooks: __MODULE__,
      audience: "keyfleet",
      body: :always
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(_conn, _headers), do: {:ok, nil}

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context) do
    with {:ok, %{assigns: %{agent_actor: agent}} = conn} <- SignedAgent.accept_agent(conn, data) do
      {:ok,
       conn
       |> Ash.PlugHelpers.set_actor(agent)
       |> Ash.PlugHelpers.set_context(%{waiter: ClientAddress.key(conn)})
       |> register_before_send(&recheck(&1, agent))}
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
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

  defp words("siwa_request_failed"), do: site_words(503, "siwa_request_failed")
  defp words("pairing_unavailable"), do: site_words(503, "pairing_unavailable")
  defp words("agent_not_paired"), do: site_words(403, "agent_not_paired")

  defp words("connection_required"),
    do:
      {401, "Connect Keyfleet to use this address.",
       "Add #{url()} to your app's connectors, such as Claude's, sign in to Keyfleet and allow both permissions."}

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
