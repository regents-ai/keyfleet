defmodule KeyfleetWeb.Plugs.NotebookGateway do
  @moduledoc """
  The only way into a fleet's notebooks. Every request to a notebook host,
  `<fleet>.<host_suffix>` (`Keyfleet.Notebooks`), stops here, before anything
  else the site serves, and reaches the fleet's hub only once this site knows
  who sent it and that they hold one of the fleet's keys now:

    * `/_keyfleet/enter?code=…` spends the one-time link "Open notebooks"
      made and sets this host's own sign-in cookie, then sends the browser to
      `/`. The cookie names the fleet and the person's account; on another
      fleet's host it signs no one in.
    * A request signed by an agent (SIWA, as on `/api/v1/agent`) is that
      agent's, whatever cookie it carries.
    * Anything else is the cookie's person's, or is refused.

  Each one's key ownership is read at most every `access_ttl_ms`
  (`Keyfleet.Notebooks.AccessCache`); the first time in that span, they are
  made an editor of the fleet's project in the hub. The token routes, with
  which a hub would hand out credentials that skip this check, are refused
  for everyone.

  What reaches the hub carries a pass for that person or agent
  (`Keyfleet.Notebooks.Pass`) in place of any `Authorization`,
  `X-KeyFleet-Assertion`, forwarded-identity or SIWA header the client sent,
  and without this site's cookie. Answers stream straight back. A WebSocket
  is carried by `KeyfleetWeb.NotebookSocket`, which closes when the key's
  holder loses it.
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{AccessCache, HubClient, Pass}
  alias KeyfleetWeb.{NotebookSocket, Refusal}
  alias KeyfleetWeb.Plugs.SignedAgent

  @cookie "__Host-kf_notebooks"
  @salt "notebook session"
  @enter "/_keyfleet/enter"

  # What a hub would hand out credentials with, or take them on: personal
  # tokens, the command line's and apps' sign-in, the MCP connection and its
  # OAuth, and a notebook's push-sync token. Compared with the decoded,
  # lowercased path, so no spelling of one reaches the hub.
  @token_prefixes ~w(
    /api/v1/me/tokens /api/v1/me/oauth-authorizations /api/v1/me/cli-authorizations
    /api/v1/me/cli-device-authorizations /api/cli/ /api/sync/ /authorize /token /register
    /revoke /mcp /.well-known/oauth-
  )
  @sync_token ~r"\A/api/v1/projects/[^/]+/notebooks/[^/]+/sync-token"

  # Never passed on: the connection's own, who the client says it is, and
  # this site's sign-in proof.
  @hop_by_hop ~w(connection keep-alive proxy-connection proxy-authenticate proxy-authorization te
    trailer transfer-encoding upgrade)
  @dropped_request ~w(host content-length cookie authorization x-keyfleet-assertion forwarded
    x-real-ip) ++ @hop_by_hop
  @handshake ~w(sec-websocket-key sec-websocket-version sec-websocket-extensions)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Notebooks.notebook_host?(conn.host), do: conn |> serve() |> halt(), else: conn
  end

  defp serve(conn) do
    with {:fleet, {:ok, fleet_id}} <- {:fleet, Notebooks.fleet_for_host(conn.host)},
         {:path, :ok} <- {:path, check_path(conn.request_path)} do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> route(fleet_id)
    else
      {:fleet, :error} -> Refusal.json(conn, 404, "notebooks_not_found")
      {:path, :invalid} -> Refusal.json(conn, 400, "invalid_request")
      {:path, :token_route} -> Refusal.json(conn, 403, "notebooks_tokens_refused")
    end
  end

  defp route(%Plug.Conn{method: "GET", request_path: @enter} = conn, fleet_id) do
    conn = fetch_query_params(conn)

    case Notebooks.redeem(fleet_id, conn.query_params["code"]) do
      {:ok, account_id} ->
        session = %{"fleet_id" => fleet_id, "account_id" => account_id}
        max_age = Notebooks.config()[:session_max_age]

        conn
        |> put_resp_cookie(
          @cookie,
          Phoenix.Token.encrypt(KeyfleetWeb.Endpoint, @salt, session, max_age: max_age),
          http_only: true,
          secure: true,
          same_site: "Lax",
          path: "/",
          max_age: max_age
        )
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("location", "/")
        |> send_resp(303, "")

      :error ->
        Refusal.json(conn, 403, "notebooks_link_used")
    end
  end

  defp route(conn, fleet_id) do
    case identify(conn, fleet_id) do
      {:ok, conn, subject, actor} -> admit(conn, fleet_id, subject, actor)
      {:refused, conn} -> conn
    end
  end

  ## Who sent it

  defp identify(conn, fleet_id) do
    if signed?(conn), do: identify_agent(conn), else: identify_person(conn, fleet_id)
  end

  defp signed?(conn),
    do:
      get_req_header(conn, "signature-input") != [] or
        get_req_header(conn, "x-siwa-receipt") != []

  defp identify_agent(conn) do
    cap = Notebooks.config()[:max_request_bytes]

    case read_body(conn, length: cap, read_length: min(cap, 1_000_000)) do
      {:ok, raw, conn} ->
        conn =
          Siwa.AgentAuthPlug.call(assign(conn, :raw_body, raw),
            client: Keyfleet.SiwaBroker,
            hooks: __MODULE__,
            audience: "keyfleet",
            signed_path: :path_and_query,
            body: :always
          )

        agent_subject(conn)

      {:more, _partial, conn} ->
        {:refused, Refusal.json(conn, 413, "request_too_large")}

      {:error, _reason} ->
        {:refused, Refusal.json(conn, 400, "invalid_request")}
    end
  end

  defp agent_subject(%Plug.Conn{halted: true} = conn), do: {:refused, conn}

  defp agent_subject(%Plug.Conn{assigns: %{agent_actor: actor}} = conn) do
    case Notebooks.agent(actor) do
      {:ok, nil} -> {:refused, Refusal.json(conn, 403, "notebooks_agent_profile")}
      {:ok, subject} -> {:ok, conn, subject, actor}
      {:error, _error} -> {:refused, Refusal.json(conn, 503, "notebooks_unavailable")}
    end
  end

  defp identify_person(conn, fleet_id) do
    conn = fetch_cookies(conn)
    max_age = Notebooks.config()[:session_max_age]

    with token when is_binary(token) <- conn.cookies[@cookie],
         {:ok, %{"fleet_id" => ^fleet_id, "account_id" => account_id}} <-
           Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, @salt, token, max_age: max_age),
         {:ok, actor} <- Notebooks.person(account_id) do
      {:ok, conn, Notebooks.subject(actor), actor}
    else
      _ -> {:refused, Refusal.json(conn, 401, "notebooks_sign_in")}
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    if SignedAgent.proof_carried?(conn),
      do: {:ok, nil},
      else: {:error, %{reason: :invalid_request}}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate accept(conn, data, context), to: SignedAgent

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate deny(conn, metadata), to: SignedAgent

  ## Whether they hold a key now

  defp admit(conn, fleet_id, subject, actor) do
    if AccessCache.admitted?(fleet_id, subject),
      do: forward(conn, fleet_id, subject),
      else: check(conn, fleet_id, subject, actor)
  end

  defp check(conn, fleet_id, subject, actor) do
    with {:holder, {:ok, true}} <- {:holder, Notebooks.member?(actor, fleet_id)},
         {:project, {:ok, project_id}} when is_binary(project_id) <-
           {:project, Notebooks.project_id(fleet_id)},
         {:hub, :ok} <- {:hub, make_editor(fleet_id, project_id, subject)} do
      AccessCache.admit(fleet_id, subject)
      forward(conn, fleet_id, subject)
    else
      {:holder, {:ok, false}} ->
        Refusal.json(conn, 403, "notebooks_not_holder")

      {:holder, {:error, _error}} ->
        Refusal.json(conn, 503, "notebooks_catching_up")

      {:project, {:ok, nil}} ->
        Oban.insert!(Notebooks.Roster.new(%{fleet_id: fleet_id}))
        Refusal.json(conn, 503, "notebooks_setting_up")

      {_step, _error} ->
        Refusal.json(conn, 502, "notebooks_unavailable")
    end
  end

  # Someone who lost a key and holds one again was suspended in the hub.
  defp make_editor(fleet_id, project_id, subject) do
    with {:ok, _added} <- HubClient.add_editor(fleet_id, project_id, subject),
         {:ok, _reactivated} <- HubClient.reactivate(fleet_id, subject) do
      :ok
    end
  end

  ## Forwarding

  defp forward(conn, fleet_id, subject) do
    {:ok, address} = Notebooks.hub_address(fleet_id)
    headers = upstream_headers(conn, fleet_id, subject)

    if websocket?(conn),
      do: forward_socket(conn, address, fleet_id, subject, headers),
      else: forward_http(conn, address, headers)
  end

  defp upstream_headers(conn, fleet_id, subject) do
    kept =
      Enum.reject(conn.req_headers, fn {name, _value} ->
        name in @dropped_request or name in SignedAgent.proof_headers() or
          String.starts_with?(name, "x-forwarded-")
      end)

    cookie =
      fetch_cookies(conn).req_cookies
      |> Map.delete(@cookie)
      |> Enum.map_join("; ", fn {name, value} -> name <> "=" <> value end)

    [{"x-keyfleet-assertion", Pass.mint(fleet_id, subject)}] ++
      if(cookie == "", do: [], else: [{"cookie", cookie}]) ++ kept
  end

  defp forward_http(conn, address, headers) do
    {body, conn} = request_body(conn)

    case body do
      :too_large ->
        Refusal.json(conn, 413, "request_too_large")

      body ->
        Req.request(
          method: conn.method,
          url: address <> target(conn),
          headers: headers,
          body: body,
          into: :self,
          raw: true,
          redirect: false,
          retry: false,
          receive_timeout: Notebooks.config()[:hub_timeout_ms]
        )
        |> stream_back(conn)
    end
  end

  # An agent's body was read to check its signature.
  defp request_body(%Plug.Conn{assigns: %{raw_body: raw}} = conn), do: {raw, conn}

  defp request_body(conn) do
    cap = Notebooks.config()[:max_request_bytes]

    case read_body(conn, length: cap, read_length: min(cap, 1_000_000)) do
      {:ok, body, conn} -> {body, conn}
      {:more, _partial, conn} -> {:too_large, conn}
      {:error, _reason} -> {:too_large, conn}
    end
  end

  defp stream_back({:ok, %Req.Response{} = response}, conn) do
    conn =
      Enum.reduce(response.headers, conn, fn {name, values}, conn ->
        if name in ["content-length" | @hop_by_hop],
          do: conn,
          else: Enum.reduce(values, conn, &prepend_resp_headers(&2, [{name, &1}]))
      end)

    if conn.method == "HEAD" or response.status in [204, 304] do
      Req.cancel_async_response(response)
      send_resp(conn, response.status, "")
    else
      conn = send_chunked(conn, response.status)
      Enum.reduce_while(response.body, conn, &send_part(response, &2, &1))
    end
  end

  defp stream_back({:error, _error}, conn), do: Refusal.json(conn, 502, "notebooks_unavailable")

  # A client that has gone stops the hub's answer too.
  defp send_part(response, conn, part) do
    case chunk(conn, part) do
      {:ok, conn} ->
        {:cont, conn}

      {:error, _closed} ->
        Req.cancel_async_response(response)
        {:halt, conn}
    end
  end

  defp websocket?(conn) do
    conn.method == "GET" and
      Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))
  end

  defp forward_socket(conn, address, fleet_id, subject, headers) do
    headers = Enum.reject(headers, fn {name, _value} -> name in @handshake end)

    case NotebookSocket.connect(address, target(conn), headers) do
      {:ok, upstream} ->
        conn
        |> put_protocol(upstream.protocol)
        |> WebSockAdapter.upgrade(
          NotebookSocket,
          Map.merge(upstream, %{fleet_id: fleet_id, subject: subject}),
          timeout: :infinity,
          compress: false
        )

      {:error, _error} ->
        Refusal.json(conn, 502, "notebooks_unavailable")
    end
  end

  defp put_protocol(conn, nil), do: conn
  defp put_protocol(conn, protocol), do: put_resp_header(conn, "sec-websocket-protocol", protocol)

  defp target(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp target(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  ## Paths

  # A hub reads a path the way a browser does: `.` and `..` segments, in any
  # spelling, move up, and a backslash is a slash. None of those reach a hub,
  # so the path compared below is the one the hub routes.
  defp check_path(path) do
    case decode(path) do
      {:ok, decoded} ->
        cond do
          String.contains?(decoded, "\\") -> :invalid
          Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."])) -> :invalid
          token_route?(String.replace(decoded, ~r"/{2,}", "/")) -> :token_route
          true -> :ok
        end

      :error ->
        :invalid
    end
  end

  defp decode(path) do
    {:ok, path |> URI.decode() |> String.downcase()}
  rescue
    ArgumentError -> :error
  end

  defp token_route?(path),
    do: String.starts_with?(path, @token_prefixes) or Regex.match?(@sync_token, path)
end
