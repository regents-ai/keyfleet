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
  endpoint's ceiling for the connector's addresses. While the app's own
  identity is paired with that same account and the person allowed Keyfleet's
  agent permission (`Keyfleet.OAuth.agent_scope/0`), the actor is that paired
  agent, as an agent signing its own requests would be
  (`KeyfleetWeb.Plugs.SignedAgent.actor_for/2`, with the token as its
  `connection`), so AshAi lists and runs the agent's tools under the same
  policies, and its identity tools besides. Otherwise the app is the actor
  (`Keyfleet.Actors.ConnectedApp`), with its identity tools only. The
  identity's wallet is read once per account (`Keyfleet.Agents.HostedAddress`),
  so a call never waits on the sign-in server. A request without a token, or
  with one this site didn't give, is asked to connect (`connection_required`),
  with the `WWW-Authenticate` challenge naming this site's sign-in and both
  permissions, so an app such as Claude starts its sign-in on its first request.

  Each answer is private and never kept (`cache-control: private, no-store`).
  Refusals answer `{"error": {"code", "message", "hint"}}`, the site's one
  shape; what a tool itself refuses comes back as the tool's error, in the
  same shape (`KeyfleetWeb.ToolErrors`).
  """

  @behaviour Plug

  import Plug.Conn

  alias Keyfleet.Actors.{Agent, ConnectedApp, Human}
  alias Keyfleet.Agents.HostedAddress
  alias KeyfleetWeb.Plugs.SignedAgent
  alias KeyfleetWeb.PublicDocuments

  # 120 requests a minute for each connected account, after the endpoint's
  # ceiling for the connector's addresses.
  @budget RegentAgentAccess.RateLimit.init(
            policy: "mcp",
            limit: 120,
            window: 60,
            admit: &Keyfleet.Accounts.RequestRateLimiter.admit/3,
            key: &__MODULE__.account/1
          )

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
        connected_app(conn)
    end
  end

  @doc false
  def account(conn) do
    case Ash.PlugHelpers.get_actor(conn) do
      %ConnectedApp{principal: principal} -> principal.subject
      %Agent{connection: principal} -> principal.subject
    end
  end

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

  defp connected_app(conn) do
    with ["Bearer " <> bearer] <- get_req_header(conn, "authorization"),
         {:ok, principal} <-
           RegentOAuth.verify(bearer, RegentOAuth.resource(), RegentMCPAgents.identity_scope()) do
      conn
      |> as_connected_app(principal)
      |> RegentAgentAccess.RateLimit.call(@budget)
    else
      _no_token_of_ours -> connect(conn)
    end
  end

  # The app's paired identity, when the person allowed it to work here as that
  # agent; the app itself otherwise. Only the token's own account chooses the
  # identity, and only a pairing with that same account, whose person is
  # here, counts.
  defp as_connected_app(conn, %{subject: subject} = principal) do
    with true <- Keyfleet.OAuth.agent_scope() in principal.scopes,
         {:ok, address} <- HostedAddress.fetch(principal),
         {:ok, %Agent{privy_user_id: ^subject, pairing: %Human{}} = agent} <-
           SignedAgent.actor_for(address, principal) do
      Ash.PlugHelpers.set_actor(conn, agent)
    else
      _not_paired_here -> Ash.PlugHelpers.set_actor(conn, %ConnectedApp{principal: principal})
    end
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

  defp words("connection_required"),
    do:
      {401, "Connect Keyfleet to use this address.",
       "Add #{url()} to your app's connectors, such as Claude's, sign in to Keyfleet and allow both permissions."}

  defp url, do: PublicDocuments.url("/mcp")
end
