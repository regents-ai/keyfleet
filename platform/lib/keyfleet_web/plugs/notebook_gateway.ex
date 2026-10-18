defmodule KeyfleetWeb.Plugs.NotebookGateway do
  @moduledoc """
  The only way into a fleet's notebooks. Every request to a notebook host,
  `<fleet>.<host_suffix>` (`Keyfleet.Notebooks`), stops here, before anything
  else the site serves, and reaches the fleet's hub only once this site knows
  who sent it and that they hold one of the fleet's keys now:

    * `/_keyfleet/enter?code=…&to=…` spends the one-time link Keyfleet made
      and sets this host's own sign-in cookie, then sends the browser to `to`:
      the start page or a saved output. The cookie names the fleet, the person's account, the Keyfleet
      sign-in it came from and when it ends; on another fleet's host it signs
      no one in, and once that Keyfleet sign-in ends (signed out, another
      account, run out) it signs no one in either, checked on every request.
    * A request signed by an agent (SIWA, as on `/api/v1/agent`) is that
      agent's, whatever cookie it carries.
    * Anything else is the cookie's person's, or is refused. A notebook page
      runs whatever its authors wrote, and a browser sends this host's cookie
      with what a page at any other keyfleet.ai address sends here. So the
      cookie signs no one in for a request that changes something, or opens a
      connection, when the browser says it came from another address
      (`from_elsewhere?/2`). The hub's own check of this reads headers that
      never reach it.

  A saved output, `/results/<notebook id>/<source id>/<saved at>`
  (`Keyfleet.Notebooks.result_url/4`), is one saved notebook page: a
  version's, or a background run's. When the hub hands back a saved page,
  this site keeps its own copy (`Keyfleet.Notebooks.SavedOutput`) and only
  then names the page's address in a `Link` header; the address shows that
  copy whatever the hub keeps, until one of the fleet's members removes it
  (`DELETE` on the address). Someone without a notebook sign-in who opens one
  is sent to Keyfleet to get one (`open_url/2`), and comes back to it.

  Background runs (the hub's jobs) start only when a member asks: a job that
  names a schedule is refused. A fleet has at most `max_sessions` notebook
  sessions open at once, whoever started them: while they are full, starting
  one for a notebook with none open is refused
  (`Keyfleet.Notebooks.session_room?/2`).

  Each one's key ownership is read at most every `access_ttl_ms`
  (`Keyfleet.AccessCache`); the first time in that span, they are
  made an editor of the fleet's project in the hub. The token routes, with
  which a hub would hand out credentials that skip this check, are refused
  for everyone.

  What reaches the hub carries a pass for that person or agent
  (`Keyfleet.Notebooks.Pass`) in place of any `Authorization`,
  `X-Keyfleet-Assertion`, forwarded-identity or SIWA header the client sent,
  and without this site's cookie. Answers stream straight back, with only the
  headers a notebook page needs (`@kept_response`). A WebSocket
  is carried by `KeyfleetWeb.NotebookSocket`, which closes when the key's
  holder loses it.

  A hub that does not answer (`Keyfleet.Notebooks.HubSilentError`), an agent's
  profile or a kept saved output that Keyfleet can't read or remove
  (`Keyfleet.Notebooks.RecordsDownError`), and a saved page shown without its copy
  kept (`Keyfleet.Notebooks.ResultNotKeptError`), are saved with the site's errors
  for someone to act on.
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias Keyfleet.{AccessCache, Notebooks}

  alias Keyfleet.Notebooks.{
    HubSilentError,
    Pass,
    RecordsDownError,
    ResultNotKeptError,
    SavedOutput
  }

  alias KeyfleetWeb.{NotebookSocket, Refusal}
  alias KeyfleetWeb.Plugs.SignedAgent

  @cookie "__Host-kf_notebooks"
  @salt "notebook session"
  @enter "/_keyfleet/enter"
  # The sign-in server checks a signed request's body inside an envelope it
  # refuses past 64 KiB, so no larger body can ever be verified.
  @signed_max_body 64 * 1024

  # Only browser notebook content and the WebSocket handshake reach the hub.
  # Cookies and all caller identity headers are replaced by our signed pass.
  @kept_request ~w(accept accept-encoding accept-language content-type content-encoding
    if-none-match if-modified-since range user-agent sec-websocket-protocol)
  # Marimo's runtime API needs its page's server token and kernel session id.
  # These select an already-admitted runtime; they never establish hub identity.
  @runtime_request ~w(marimo-server-token marimo-session-id)
  # Only what a notebook page reads from the hub's answers comes back: the
  # content and how it is encoded, what makes caching, ranges, downloads and
  # redirects work, the two headers the notebook app reads on a snapshot, and
  # the security headers the hub sets on its pages, which only restrict them.
  # Cookies, credentials, cross-origin grants and caching rules never do; this
  # site's own `no-store` stands.
  @kept_response ~w(content-type content-encoding content-language content-disposition
    content-range accept-ranges etag last-modified vary location retry-after
    x-marimohub-version-id x-marimohub-captured-at
    content-security-policy content-security-policy-report-only cross-origin-opener-policy
    cross-origin-resource-policy cross-origin-embedder-policy origin-agent-cluster
    referrer-policy strict-transport-security x-content-type-options x-frame-options
    x-dns-prefetch-control x-download-options x-permitted-cross-domain-policies x-xss-protection)
  @handshake ~w(sec-websocket-key sec-websocket-version sec-websocket-extensions)

  # Notebook UI operations in marimohub f103eb2. Newly added routes stay closed
  # until reviewed here; credentials, admin, OAuth, MCP and sync routes are absent.
  @api_routes [
    "GET /api/v1/me",
    "GET /api/v1/version",
    "GET /api/v1/capabilities",
    "GET /api/v1/theme",
    "GET /api/v1/projects",
    "GET /api/v1/projects/:pid",
    "GET /api/v1/events",
    "GET /api/v1/projects/:pid/events",
    "GET /api/v1/projects/:pid/thumbnails",
    "GET /api/v1/apps",
    "GET /api/v1/projects/:pid/notebooks/:nid/app",
    "GET /api/v1/projects/:pid/sessions",
    "GET /api/v1/projects/:pid/notebooks/:nid/deep-links",
    "POST /api/v1/projects/:pid/notebooks/:nid/deep-links",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/deep-links/:slug",
    "GET /api/v1/projects/:pid/notebooks",
    "POST /api/v1/projects/:pid/notebooks",
    "POST /api/v1/projects/:pid/notebooks/git",
    "PATCH /api/v1/projects/:pid/notebooks/:nid/source",
    "GET /api/v1/projects/:pid/notebooks/:nid/source/drift",
    "POST /api/v1/projects/:pid/notebooks/:nid/source/sync",
    "GET /api/v1/projects/:pid/notebooks/:nid",
    "GET /api/v1/projects/:pid/notebooks/:nid/content",
    "PATCH /api/v1/projects/:pid/notebooks/:nid",
    "PUT /api/v1/projects/:pid/notebooks/:nid/security-labels",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/security-labels",
    "DELETE /api/v1/projects/:pid/notebooks/:nid",
    "GET /api/v1/projects/:pid/notebooks/:nid/versions",
    "GET /api/v1/projects/:pid/notebooks/:nid/versions/:vid",
    "GET /api/v1/projects/:pid/notebooks/:nid/html",
    "GET /api/v1/projects/:pid/notebooks/:nid/versions/:vid/html",
    "POST /api/v1/projects/:pid/notebooks/:nid/versions/:vid/restore",
    "POST /api/v1/projects/:pid/notebooks/:nid/duplicate",
    "GET /api/v1/projects/:pid/notebooks/:nid/workspace/access",
    "GET /api/v1/projects/:pid/notebooks/:nid/workspace/entries",
    "GET /api/v1/projects/:pid/notebooks/:nid/workspace/search",
    "POST /api/v1/projects/:pid/notebooks/:nid/workspace/directories",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/workspace/entries",
    "GET /api/v1/projects/:pid/notebooks/:nid/workspace/files",
    "PUT /api/v1/projects/:pid/notebooks/:nid/workspace/files",
    "POST /api/v1/projects/:pid/notebooks/:nid/sessions",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/sessions/:sid",
    "GET /api/v1/projects/:pid/notebooks/:nid/sessions/:sid",
    "POST /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/heartbeat",
    "POST /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/leave",
    "POST /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/surfaces/:surface",
    "GET /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/surfaces/:surface",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/surfaces/:surface",
    "GET /api/v1/projects/:pid/notebooks/:nid/editor-session",
    "POST /api/v1/projects/:pid/notebooks/:nid/editor-session/takeover",
    "POST /api/v1/projects/:pid/notebooks/:nid/sessions/:sid/change-requests",
    "GET /api/v1/projects/:pid/notebooks/:nid/jobs",
    "POST /api/v1/projects/:pid/notebooks/:nid/jobs",
    "GET /api/v1/projects/:pid/notebooks/:nid/jobs/:jid",
    "PATCH /api/v1/projects/:pid/notebooks/:nid/jobs/:jid",
    "DELETE /api/v1/projects/:pid/notebooks/:nid/jobs/:jid",
    "POST /api/v1/projects/:pid/notebooks/:nid/jobs/:jid/runs",
    "GET /api/v1/projects/:pid/notebooks/:nid/jobs/:jid/runs",
    "GET /api/v1/projects/:pid/notebooks/:nid/jobs/:jid/runs/:rid",
    "POST /api/v1/projects/:pid/notebooks/:nid/jobs/:jid/runs/:rid/cancel",
    "GET /api/v1/projects/:pid/notebooks/:nid/jobs/:jid/runs/:rid/html"
  ]
  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Notebooks.notebook_host?(conn.host), do: conn |> serve() |> halt(), else: conn
  end

  defp serve(conn) do
    if KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?() do
      serve_open(conn)
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("retry-after", "3600")
      |> Refusal.json(503, "not_open_yet")
    end
  end

  defp serve_open(conn) do
    with {:fleet, {:ok, fleet_id}} <- {:fleet, Notebooks.fleet_for_host(conn.host)},
         {:path, :ok} <- {:path, check_path(conn.method, conn.request_path)} do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> route(fleet_id)
    else
      {:fleet, :error} -> Refusal.json(conn, 404, "notebooks_not_found")
      {:path, :invalid} -> Refusal.json(conn, 400, "invalid_request")
      {:path, :route_refused} -> Refusal.json(conn, 403, "notebooks_tokens_refused")
    end
  end

  defp route(%Plug.Conn{method: "GET", request_path: @enter} = conn, fleet_id) do
    conn = fetch_query_params(conn)
    to = conn.query_params["to"]

    if Notebooks.destination?(to),
      do: enter(conn, fleet_id, to),
      else: Refusal.json(conn, 400, "invalid_request")
  end

  defp route(conn, fleet_id) do
    case identify(conn, fleet_id) do
      {:ok, conn, subject, actor} -> admit(conn, fleet_id, subject, actor)
      {:refused, conn} -> conn
    end
  end

  # The link lands where it was made for: the start page or a saved output.
  defp enter(conn, fleet_id, to) do
    case Notebooks.redeem(fleet_id, conn.query_params["code"]) do
      {:ok, {account_id, session_authority_id}} ->
        max_age = Notebooks.config()[:session_max_age]

        session = %{
          "fleet_id" => fleet_id,
          "account_id" => account_id,
          "session_authority_id" => session_authority_id,
          "ends_at" => System.os_time(:second) + max_age
        }

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
        |> put_resp_header("location", to)
        |> send_resp(303, "")

      :error ->
        Refusal.json(conn, 403, "notebooks_link_used")
    end
  end

  ## Who sent it

  defp identify(conn, fleet_id) do
    if Siwa.AgentAuthPlug.signed_request?(conn),
      do: identify_agent(conn, fleet_id),
      else: identify_person(conn, fleet_id)
  end

  # A signed request spends the sender's address's API budget before anything
  # of it is read, and only as much body is read as a signature can cover.
  defp identify_agent(conn, fleet_id) do
    conn = RegentAgentAccess.RateLimit.call(conn, KeyfleetWeb.Endpoint.api_rate_limit())
    if conn.halted, do: {:refused, conn}, else: read_signed(conn, fleet_id)
  end

  defp read_signed(conn, fleet_id) do
    case read_body_signed(conn) do
      {:ok, _raw, conn} ->
        conn =
          Siwa.AgentAuthPlug.call(conn,
            client: Keyfleet.SiwaBroker,
            hooks: __MODULE__,
            audience: "keyfleet",
            query: :signed,
            body: :always
          )

        agent_subject(conn, fleet_id)

      {:more, _partial, conn} ->
        {:refused, Refusal.json(conn, 413, "request_too_large")}

      :too_large ->
        {:refused, Refusal.json(conn, 413, "request_too_large")}

      {:error, _reason} ->
        {:refused, Refusal.json(conn, 400, "invalid_request")}
    end
  end

  defp read_body_signed(conn) do
    Siwa.AgentAuthPlug.read_body(conn, [], @signed_max_body)
  rescue
    Plug.Parsers.RequestTooLargeError -> :too_large
  end

  defp agent_subject(%Plug.Conn{halted: true} = conn, _fleet_id), do: {:refused, conn}

  defp agent_subject(%Plug.Conn{assigns: %{agent_actor: actor}} = conn, fleet_id) do
    case Notebooks.agent(actor) do
      {:ok, nil} ->
        {:refused, Refusal.json(conn, 403, "notebooks_agent_profile")}

      {:ok, subject} ->
        {:ok, conn, subject, actor}

      {:error, error} ->
        RecordsDownError.report(
          "The profile of an agent opening the notebooks of #{fleet_id} could not be read: " <>
            inspect(error.__struct__)
        )

        {:refused, Refusal.json(conn, 503, "notebooks_unavailable")}
    end
  end

  defp identify_person(conn, fleet_id) do
    if from_elsewhere?(conn, fleet_id),
      do: {:refused, Refusal.json(conn, 403, "notebooks_other_site")},
      else: cookie_person(conn, fleet_id)
  end

  # What a browser says of where a request came from: `Origin` names the page's
  # address, `Sec-Fetch-Site` how it relates to this one. A read is not asked.
  defp from_elsewhere?(conn, fleet_id) do
    (conn.method not in ["GET", "HEAD"] or websocket?(conn)) and
      (Enum.any?(get_req_header(conn, "origin"), &(&1 != Notebooks.url(fleet_id, nil))) or
         Enum.any?(get_req_header(conn, "sec-fetch-site"), &(&1 in ["same-site", "cross-site"])))
  end

  defp cookie_person(conn, fleet_id) do
    conn = fetch_cookies(conn)
    max_age = Notebooks.config()[:session_max_age]

    with token when is_binary(token) <- conn.cookies[@cookie],
         {:ok,
          %{
            "fleet_id" => ^fleet_id,
            "account_id" => account_id,
            "session_authority_id" => session_authority_id,
            "ends_at" => pass_ends_at
          }} <- Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, @salt, token, max_age: max_age),
         {:ok, actor, topic, sign_in_ends_at} <-
           Notebooks.person(session_authority_id, account_id) do
      ends_at = Enum.min([DateTime.from_unix!(pass_ends_at), sign_in_ends_at], DateTime)

      conn =
        assign(conn, :notebook_sign_in, %{
          topic: topic,
          ends_at: ends_at,
          session_authority_id: session_authority_id,
          account_id: account_id
        })

      {:ok, conn, Notebooks.subject(actor), actor}
    else
      _ -> {:refused, sign_in(conn, fleet_id)}
    end
  end

  # A saved output's address is shared in the workspace, so someone without a
  # notebook sign-in who opens one goes to Keyfleet, which signs them in to the
  # fleet's notebooks if they hold one of its keys and brings them back here.
  defp sign_in(%Plug.Conn{method: method, request_path: "/results/" <> _ = path} = conn, fleet_id)
       when method in ["GET", "HEAD"] do
    conn
    |> put_resp_header("location", open_url(fleet_id, path))
    |> send_resp(303, "")
  end

  defp sign_in(conn, _fleet_id), do: Refusal.json(conn, 401, "notebooks_sign_in")

  @doc """
  Keyfleet's address that signs a person in to the fleet's notebooks and
  lands them on `to` (`KeyfleetWeb.NotebookOpenController`).
  """
  def open_url(fleet_id, to),
    do:
      KeyfleetWeb.Endpoint.url() <>
        "/fleets/#{fleet_id}/notebooks/open?" <> URI.encode_query(to: to)

  # The shared plug has already refused a repeated signed header and a body it
  # did not capture whole; nothing else is checked before the sign-in server.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(_conn, _headers), do: {:ok, nil}

  # The body goes to the hub as it came; only who sent it is checked here.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context), do: SignedAgent.accept_agent(conn, data)

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate deny(conn, metadata), to: SignedAgent

  ## Whether they hold a key now

  defp admit(conn, fleet_id, subject, %Keyfleet.Actors.Agent{} = actor),
    do: check(conn, fleet_id, subject, actor)

  defp admit(conn, fleet_id, subject, actor) do
    case AccessCache.lookup(:notebooks, fleet_id, subject) do
      {:ok, true} -> forward(conn, fleet_id, subject)
      :none -> check(conn, fleet_id, subject, actor)
    end
  end

  defp check(conn, fleet_id, subject, actor) do
    case Notebooks.admit(actor, fleet_id, subject) do
      {:ok, _project_id} -> forward(conn, fleet_id, subject)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, :not_holder), do: Refusal.json(conn, 403, "notebooks_not_holder")
  defp refuse(conn, :catching_up), do: Refusal.json(conn, 503, "notebooks_catching_up")
  defp refuse(conn, :setting_up), do: Refusal.json(conn, 503, "notebooks_setting_up")
  defp refuse(conn, :unavailable), do: Refusal.json(conn, 502, "notebooks_unavailable")

  ## Forwarding

  defp forward(
         %Plug.Conn{method: "DELETE", request_path: "/results/" <> _ = path} = conn,
         fleet_id,
         _subject
       ),
       do: remove_saved_output(conn, fleet_id, path)

  defp forward(%Plug.Conn{request_path: "/results/" <> _ = path} = conn, fleet_id, _subject),
    do: send_saved_output(conn, fleet_id, path)

  # A fleet has at most `max_sessions` notebook sessions open at once.
  defp forward(
         %Plug.Conn{
           method: "POST",
           path_info: ["api", "v1", "projects", _project, "notebooks", notebook_id, "sessions"]
         } = conn,
         fleet_id,
         subject
       ) do
    case Notebooks.session_room?(fleet_id, notebook_id) do
      {:ok, true} -> to_hub(conn, fleet_id, subject)
      {:ok, false} -> Refusal.json(conn, 429, "notebook_sessions_full")
      {:error, :unavailable} -> refuse(conn, :unavailable)
    end
  end

  defp forward(conn, fleet_id, subject), do: to_hub(conn, fleet_id, subject)

  defp to_hub(conn, fleet_id, subject) do
    {:ok, address} = Notebooks.hub_address(fleet_id)
    headers = upstream_headers(conn, fleet_id, subject)

    if websocket?(conn),
      do: forward_socket(conn, address, fleet_id, subject, headers),
      else: forward_http(conn, address, fleet_id, headers)
  end

  # A saved page is asked for unencoded, so the copy kept of it is the page.
  defp upstream_headers(conn, fleet_id, subject) do
    allowed =
      cond do
        String.starts_with?(conn.request_path, ["/proxy/", "/surface-proxy/"]) ->
          @kept_request ++ @runtime_request

        saved_page_notebook(conn.path_info) != :error ->
          @kept_request -- ["accept-encoding"]

        true ->
          @kept_request
      end

    kept = Enum.filter(conn.req_headers, fn {name, _value} -> name in allowed end)
    [{"x-keyfleet-assertion", Pass.mint(fleet_id, subject)} | kept]
  end

  defp forward_http(conn, address, fleet_id, headers) do
    {body, conn} = request_body(conn)

    cond do
      body == :too_large ->
        Refusal.json(conn, 413, "request_too_large")

      not job_unscheduled?(conn, body) ->
        Refusal.json(conn, 403, "notebooks_schedules_refused")

      true ->
        Req.request(
          method: conn.method,
          url: address <> target(conn),
          headers: headers,
          body: body,
          into: :self,
          raw: true,
          redirect: false,
          retry: false,
          receive_timeout: http_timeout(conn)
        )
        |> stream_back(conn, fleet_id)
    end
  end

  defp http_timeout(%{
         method: "POST",
         path_info: ["api", "v1", "projects", _project, "notebooks", _notebook, "sessions"]
       }),
       do: Notebooks.config()[:session_start_timeout_ms]

  defp http_timeout(_conn), do: Notebooks.config()[:hub_timeout_ms]

  # A job runs only when a member starts it: one that names a schedule is
  # refused (clearing a schedule with `null` is not naming one).
  defp job_unscheduled?(
         %Plug.Conn{
           method: "POST",
           path_info: ["api", "v1", "projects", _, "notebooks", _, "jobs"]
         } = conn,
         body
       ),
       do: no_schedule?(conn, body)

  defp job_unscheduled?(
         %Plug.Conn{
           method: "PATCH",
           path_info: ["api", "v1", "projects", _, "notebooks", _, "jobs", _]
         } = conn,
         body
       ),
       do: no_schedule?(conn, body)

  defp job_unscheduled?(_conn, _body), do: true

  defp no_schedule?(conn, body) do
    with [] <- get_req_header(conn, "content-encoding"),
         {:ok, %{} = job} <- Jason.decode(body) do
      is_nil(job["schedule"])
    else
      _ -> false
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

  defp stream_back({:error, error}, conn, fleet_id) do
    HubSilentError.report(
      "The notebook hub of #{fleet_id} did not answer a request: #{inspect(error)}"
    )

    Refusal.json(conn, 502, "notebooks_unavailable")
  end

  defp stream_back({:ok, %Req.Response{} = response}, conn, fleet_id) do
    conn =
      Enum.reduce(response.headers, conn, fn {name, values}, conn ->
        if name in @kept_response,
          do: Enum.reduce(values, conn, &prepend_resp_headers(&2, [{name, &1}])),
          else: conn
      end)

    cond do
      conn.method == "HEAD" or response.status in [204, 304] ->
        Req.cancel_async_response(response)
        send_resp(conn, response.status, "")

      address = saved_page_address(conn, response) ->
        keep_page(response, conn, fleet_id, address)

      true ->
        conn = send_chunked(conn, response.status)
        Enum.reduce_while(response.body, conn, &send_part(response, &2, &1))
    end
  end

  # The saved page a notebook's page routes hand back, as `{notebook id,
  # source id, saved at}`, or nil for any other answer. A version's page names
  # its version, a background run's page its run.
  defp saved_page_address(conn, response) do
    with 200 <- response.status,
         {:ok, notebook_id, source_header} <- saved_page_notebook(conn.path_info),
         [] <- Req.Response.get_header(response, "content-encoding"),
         [source_id] <- Req.Response.get_header(response, source_header),
         [captured_at] <- Req.Response.get_header(response, "x-marimohub-captured-at"),
         {:ok, saved_at} <- Notebooks.saved_at(captured_at),
         {:ok, address} <-
           Notebooks.result(Notebooks.result_path(notebook_id, source_id, saved_at)) do
      address
    else
      _ -> nil
    end
  end

  # A saved page is read whole, kept, and only then sent with its address, so
  # an address is never handed out for a page Keyfleet hasn't kept. A page past
  # `saved_page_max_bytes` goes on streaming as it came, with no address.
  defp keep_page(response, conn, fleet_id, address) do
    cap = Notebooks.config()[:saved_page_max_bytes]

    response.body
    |> Enum.reduce_while({:reading, conn, [], 0}, fn
      part, {:reading, conn, parts, size} when size + byte_size(part) <= cap ->
        {:cont, {:reading, conn, [parts | part], size + byte_size(part)}}

      part, {:reading, conn, parts, _size} ->
        conn = send_chunked(conn, response.status)

        case chunk(conn, [parts | part]) do
          {:ok, conn} -> {:cont, {:streaming, conn}}
          {:error, _closed} -> {:halt, {:streaming, conn}}
        end

      part, {:streaming, conn} ->
        case send_part(response, conn, part) do
          {:cont, conn} -> {:cont, {:streaming, conn}}
          {:halt, conn} -> {:halt, {:streaming, conn}}
        end
    end)
    |> case do
      {:reading, conn, parts, _size} -> send_kept(conn, fleet_id, address, parts)
      {:streaming, conn} -> conn
    end
  end

  defp send_kept(conn, fleet_id, {notebook_id, source_id, saved_at}, parts) do
    page = IO.iodata_to_binary(parts)

    case Notebooks.keep_saved_output(fleet_id, notebook_id, source_id, saved_at, page,
           actor: %Keyfleet.Actors.System{}
         ) do
      {:ok, _kept} ->
        conn
        |> put_result_link(fleet_id, notebook_id, source_id, saved_at)
        |> send_resp(200, page)

      {:error, error} ->
        ResultNotKeptError.report(
          "A saved page of notebook #{notebook_id} in #{fleet_id} was shown without its " <>
            "lasting address: " <> Exception.message(error)
        )

        send_resp(conn, 200, page)
    end
  end

  # Any of the fleet's members may remove a saved output: its copy is deleted
  # and the address is gone.
  defp remove_saved_output(conn, fleet_id, path) do
    {:ok, {notebook_id, source_id, saved_at}} = Notebooks.result(path)
    system = %Keyfleet.Actors.System{}

    with {:ok, %SavedOutput{} = kept} <-
           Notebooks.saved_output(fleet_id, notebook_id, source_id, saved_at, actor: system),
         :ok <- Notebooks.remove_saved_output(kept, actor: system) do
      send_resp(conn, 204, "")
    else
      {:ok, nil} ->
        Refusal.json(conn, 404, "notebooks_not_found")

      {:error, error} ->
        RecordsDownError.report(
          "A saved output of notebook #{notebook_id} in #{fleet_id} could not be removed: " <>
            inspect(error.__struct__)
        )

        Refusal.json(conn, 503, "notebooks_unavailable")
    end
  end

  # A saved output's address shows Keyfleet's copy, whatever the hub keeps now.
  defp send_saved_output(conn, fleet_id, path) do
    {:ok, {notebook_id, source_id, saved_at}} = Notebooks.result(path)

    case Notebooks.saved_output(fleet_id, notebook_id, source_id, saved_at,
           actor: %Keyfleet.Actors.System{}
         ) do
      {:ok, %SavedOutput{page: page}} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("content-security-policy", "sandbox allow-scripts")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_result_link(fleet_id, notebook_id, source_id, saved_at)
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: page))

      {:ok, nil} ->
        Refusal.json(conn, 404, "notebooks_not_found")

      {:error, error} ->
        RecordsDownError.report(
          "A saved output of notebook #{notebook_id} in #{fleet_id} could not be read: " <>
            inspect(error.__struct__)
        )

        Refusal.json(conn, 503, "notebooks_unavailable")
    end
  end

  # A kept page names its address, so whoever read it can link the result
  # from the workspace.
  defp put_result_link(conn, fleet_id, notebook_id, source_id, saved_at) do
    put_resp_header(
      conn,
      "link",
      "<#{Notebooks.result_url(fleet_id, notebook_id, source_id, saved_at)}>; rel=\"canonical\""
    )
  end

  defp saved_page_notebook(["api", "v1", "projects", _project, "notebooks", notebook_id, "html"]),
    do: {:ok, notebook_id, "x-marimohub-version-id"}

  defp saved_page_notebook([
         "api",
         "v1",
         "projects",
         _project,
         "notebooks",
         notebook_id,
         "jobs",
         _job,
         "runs",
         _run,
         "html"
       ]),
       do: {:ok, notebook_id, "x-marimohub-run-id"}

  defp saved_page_notebook([
         "api",
         "v1",
         "projects",
         _project,
         "notebooks",
         notebook_id,
         "versions",
         _version,
         "html"
       ]),
       do: {:ok, notebook_id, "x-marimohub-version-id"}

  defp saved_page_notebook(_path_info), do: :error

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
          Map.merge(upstream, %{
            fleet_id: fleet_id,
            subject: subject,
            holder: holder(conn),
            sign_in_topic: sign_in_topic(conn),
            sign_in_ends_at: sign_in_ends_at(conn)
          }),
          timeout: :infinity,
          compress: false
        )

      {:error, reason} ->
        HubSilentError.report(
          "The notebook hub of #{fleet_id} refused a live connection: #{inspect(reason)}"
        )

        Refusal.json(conn, 502, "notebooks_unavailable")
    end
  end

  # Who the connection is for, as the connection reads them again once it is
  # listening (`KeyfleetWeb.NotebookSocket`): a person by the Keyfleet sign-in
  # their cookie came from, an agent as its signed request named it.
  defp holder(%Plug.Conn{assigns: %{notebook_sign_in: sign_in}}),
    do: {:person, sign_in.session_authority_id, sign_in.account_id}

  defp holder(%Plug.Conn{assigns: %{agent_actor: agent}}), do: {:agent, agent}

  # A person's sign-in is their notebook cookie, which ends at its own end or
  # the Keyfleet sign-in it came from, whichever is sooner, and also when they
  # sign out there; an agent's is the receipt its request was signed with.
  defp sign_in_topic(%Plug.Conn{assigns: %{notebook_sign_in: sign_in}}), do: sign_in.topic
  defp sign_in_topic(_conn), do: nil

  defp sign_in_ends_at(%Plug.Conn{assigns: %{notebook_sign_in: sign_in}}), do: sign_in.ends_at
  defp sign_in_ends_at(%Plug.Conn{assigns: %{agent_actor: agent}}), do: agent.receipt_expires_at

  defp put_protocol(conn, nil), do: conn
  defp put_protocol(conn, protocol), do: put_resp_header(conn, "sec-websocket-protocol", protocol)

  defp target(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp target(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  ## Paths

  # A hub reads a path the way a browser does: `.` and `..` segments, in any
  # spelling, move up, and a backslash is a slash. None of those reach a hub,
  # so the path compared below is the one the hub routes.
  # A saved output's address has one spelling, which needs no decoding, and so
  # has every API route: what this site checks of a route (the session cap, a
  # job's schedule) reads the path as it came, so that must be what the hub routes.
  defp check_path(method, "/results/" <> _ = path) when method in ["GET", "HEAD", "DELETE"],
    do: if(Notebooks.result(path) == :error, do: :invalid, else: :ok)

  defp check_path(method, path) do
    case decode(path) do
      {:ok, decoded} ->
        cond do
          String.contains?(decoded, "\\") -> :invalid
          Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."])) -> :invalid
          not allowed_route?(method, decoded) -> :route_refused
          String.starts_with?(decoded, "/api/") and decoded != path -> :invalid
          true -> :ok
        end

      :error ->
        :invalid
    end
  end

  defp decode(path) do
    decoded = URI.decode(path)
    # A second decoding must not turn a permitted path into another route.
    if String.contains?(decoded, ["%", "\0"]), do: :error, else: {:ok, decoded}
  rescue
    ArgumentError -> :error
  end

  defp allowed_route?("HEAD", path), do: allowed_route?("GET", path)

  defp allowed_route?("GET", @enter), do: true
  defp allowed_route?("GET", "/"), do: true
  defp allowed_route?("GET", "/api/health"), do: true
  defp allowed_route?("GET", "/favicon.ico"), do: true
  defp allowed_route?("GET", "/manifest.webmanifest"), do: true
  defp allowed_route?("GET", "/assets/" <> _file), do: true
  defp allowed_route?("GET", "/projects/" <> _page), do: true
  defp allowed_route?("GET", "/proxy/" <> path), do: path != ""
  defp allowed_route?("POST", "/proxy/" <> path), do: path != ""
  defp allowed_route?("GET", "/surface-proxy/" <> path), do: path != ""
  defp allowed_route?("POST", "/surface-proxy/" <> path), do: path != ""

  defp allowed_route?(method, path) do
    parts = String.split(path, "/", trim: false)

    Enum.any?(@api_routes, fn route ->
      [verb, pattern] = String.split(route, " ", parts: 2)
      expected = String.split(pattern, "/", trim: false)

      method == verb and length(parts) == length(expected) and
        Enum.zip(parts, expected)
        |> Enum.all?(&matching_segment?/1)
    end)
  end

  defp matching_segment?({actual, ":" <> _name}), do: actual != ""
  defp matching_segment?({actual, wanted}), do: actual == wanted
end
