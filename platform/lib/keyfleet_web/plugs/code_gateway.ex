defmodule KeyfleetWeb.Plugs.CodeGateway do
  @moduledoc """
  The only way into the fleets' code (`Keyfleet.Code`). Every request to the
  code host stops here, before anything else the site serves, and reaches the
  code store only once this site knows who sent it and that they hold one of
  the fleet's keys now.

  Git asks at `/<fleet id>.git` for the three things it needs, and nothing
  else is answered: what the repository holds (`info/refs`), a copy
  (`git-upload-pack`) and changes sent (`git-receive-pack`). Who sent it:

    * An agent signs every request with its own sign-in (SIWA, as on
      `/api/v1/agent`): its method, its path with the query, and the digest
      of its exact body, an empty one included. The whole body, a pack
      included, is read first, up to `max_pack_bytes`, so the sign-in server
      checks the digest of the very bytes the store is then sent; nothing
      reaches the store before that. The agent is then let in by what its own
      wallet holds or by its pairing with a holder, checked on every request.
    * A person signs in with a password from `KeyfleetWeb.CodePassword`, under
      any user name, checked at most every `access_ttl_ms`.

  A key changing hands clears the fleet's admissions at once.

  What reaches the store carries a pass (`Keyfleet.Code.Pass`) in place of
  any sign-in, with only the headers git's exchange needs. The store's answer
  streams back. When the store reports changes done, each branch or tag moved
  is recorded for the fleet's workspace, under the key and, for an agent,
  the agent too. A store that cannot be reached, stops mid-exchange or answers
  with a fault of its own is saved with the site's errors
  (`Keyfleet.Code.StoreDown`).
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias Keyfleet.Code
  alias Keyfleet.Code.{Pass, ReceivePack, StoreDown}
  alias KeyfleetWeb.{CodePassword, Refusal}
  alias KeyfleetWeb.Plugs.SignedAgent

  @services ~w(git-upload-pack git-receive-pack)
  @fleet_id ~r/\A[a-z0-9_]{1,64}\z/

  # Only what git's exchange needs passes either way.
  @kept_request ~w(accept accept-encoding content-encoding content-type git-protocol user-agent)
  @kept_response ~w(cache-control content-encoding content-type expires pragma)

  # Enough of each side of a push to read its commands and the store's report.
  @captured 65_536

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if conn.host == Code.config()[:host], do: conn |> serve() |> halt(), else: conn
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
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:route, {:ok, fleet_id, need, target}} <- {:route, route(conn)},
         {:signed_in, {:ok, conn, subject, actor}} <- {:signed_in, identify(conn, fleet_id)},
         {:holder, {:ok, %{} = holder}} <-
           {:holder, current_holder(fleet_id, subject, actor)},
         {:allowed, {:ok, pass}} <- {:allowed, pass(fleet_id, holder, need)},
         {:owner, {:ok, owner}} <- {:owner, Code.owner(fleet_id)} do
      forward(
        conn,
        fleet_id,
        "/#{owner}/#{fleet_id}/#{target}",
        pass,
        &sent(conn, fleet_id, holder, &1, &2)
      )
    else
      {:route, :error} ->
        refuse(conn, 404, "code_not_found")

      {:signed_in, {:refused, conn}} ->
        conn

      {:holder, {:ok, nil}} ->
        refuse(conn, 403, "code_not_holder")

      {:holder, {:error, _error}} ->
        refuse(conn, 503, "code_catching_up")

      {:allowed, :restricted} ->
        refuse(conn, 403, "code_edits_restricted")

      {:owner, :setting_up} ->
        refuse(conn, 503, "code_setting_up")

      {:owner, {:error, _error}} ->
        refuse(conn, 503, "code_unavailable")
    end
  end

  defp current_holder(fleet_id, _subject, %Keyfleet.Actors.Agent{} = actor),
    do: Code.holder(actor, fleet_id)

  defp current_holder(fleet_id, subject, actor),
    do: Code.admitted(fleet_id, subject, fn -> Code.holder(actor, fleet_id) end)

  # When the store took a push, what it moved is recorded under the holder.
  defp sent(
         %Plug.Conn{method: "POST", path_info: [_repository, "git-receive-pack"]},
         fleet_id,
         holder,
         request,
         response
       ),
       do: Code.record_pushes(fleet_id, holder, ReceivePack.updates(request, response))

  defp sent(_conn, _fleet_id, _holder, _request, _response), do: :ok

  ## What is asked

  defp route(%Plug.Conn{method: "GET", path_info: [repository, "info", "refs"]} = conn) do
    conn = fetch_query_params(conn)

    with {:ok, fleet_id} <- fleet(repository),
         %{"service" => service} when service in @services <- conn.query_params do
      {:ok, fleet_id, need(service), "info/refs?service=" <> service}
    else
      _other -> :error
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: [repository, service]})
       when service in @services do
    with {:ok, fleet_id} <- fleet(repository), do: {:ok, fleet_id, need(service), service}
  end

  defp route(_conn), do: :error

  defp fleet(repository) do
    fleet_id = String.replace_suffix(repository, ".git", "")

    if fleet_id <> ".git" == repository and Regex.match?(@fleet_id, fleet_id),
      do: {:ok, fleet_id},
      else: :error
  end

  defp need("git-upload-pack"), do: :read
  defp need("git-receive-pack"), do: :push

  ## Who sent it

  defp identify(conn, fleet_id) do
    if Siwa.AgentAuthPlug.signed_request?(conn),
      do: identify_agent(conn),
      else: identify_person(conn, fleet_id)
  end

  # A signed request spends the sender's address's API budget before its body
  # is read.
  defp identify_agent(conn) do
    conn = RegentAgentAccess.RateLimit.call(conn, KeyfleetWeb.Endpoint.api_rate_limit())
    if conn.halted, do: {:refused, conn}, else: read_signed(conn)
  end

  defp read_signed(conn) do
    with {:ok, conn} <- read_whole(conn) do
      conn
      |> Siwa.AgentAuthPlug.call(
        client: Keyfleet.SiwaBroker,
        hooks: __MODULE__,
        audience: "keyfleet",
        query: :signed,
        body: :always
      )
      |> agent()
    end
  end

  defp agent(%Plug.Conn{halted: true} = conn), do: {:refused, conn}
  defp agent(%Plug.Conn{assigns: %{agent_actor: actor}} = conn), do: {:ok, conn, nil, actor}

  # A person's body is read only once their password stands.
  defp identify_person(conn, fleet_id) do
    with {_user, password} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, subject, actor} <- CodePassword.read(password, fleet_id),
         {:ok, conn} <- read_whole(conn) do
      {:ok, conn, subject, actor}
    else
      {:refused, conn} ->
        {:refused, conn}

      :error ->
        {:refused,
         conn
         |> put_resp_header("www-authenticate", ~s(Basic realm="Keyfleet code"))
         |> refuse(401, "code_sign_in")}
    end
  end

  # The whole body is kept as it came (`conn.assigns.raw_body`), a read's
  # empty one included: a signature covers these exact bytes, and the store
  # is sent them. The shared reader asks for it in one read, so the read is
  # given as long as a large push takes to arrive.
  defp read_whole(conn) do
    case Siwa.AgentAuthPlug.read_body(
           conn,
           [read_timeout: Code.config()[:body_timeout_ms]],
           Code.config()[:max_pack_bytes]
         ) do
      {:ok, _body, conn} -> {:ok, conn}
      {:more, _partial, conn} -> {:refused, refuse(conn, 413, "code_too_large")}
      {:error, _reason} -> {:refused, refuse(conn, 400, "invalid_request")}
    end
  rescue
    Plug.Parsers.RequestTooLargeError -> {:refused, refuse(conn, 413, "code_too_large")}
  end

  # The shared plug has already refused a repeated signed header and a body it
  # did not capture whole; nothing else is checked before the sign-in server.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(_conn, _headers), do: {:ok, nil}

  # Only who sent it is checked here; whether they may use the code comes next.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context), do: SignedAgent.accept_agent(conn, data)

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate deny(conn, metadata), to: SignedAgent

  # A key whose edits a vote restricted may still copy the code.
  defp pass(fleet_id, %{restricted?: true}, :read), do: {:ok, Pass.read(fleet_id)}
  defp pass(_fleet_id, %{restricted?: true}, :push), do: :restricted
  defp pass(fleet_id, %{wallet: wallet}, _need), do: {:ok, Pass.push(fleet_id, wallet)}

  # Git shows a plain-text answer to the person running it.
  defp refuse(conn, status, code) do
    %{error: %{message: message, hint: hint}} = Refusal.body(code)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message <> "\n" <> hint <> "\n")
  end

  ## Forwarding

  # `done` is told the start of the request and of the answer once the store
  # has answered in full and the answer reached the client.
  defp forward(conn, fleet_id, path, pass, done) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Code.config()[:node])

    headers = [
      {"authorization", "Bearer " <> pass}
      | for({name, value} <- conn.req_headers, name in @kept_request, do: {name, value})
    ]

    body = if conn.method == "POST", do: conn.assigns.raw_body

    with {:ok, node} <-
           Mint.HTTP.connect(String.to_existing_atom(scheme), host, port,
             mode: :passive,
             protocols: [:http1]
           ),
         {:ok, node, ref} <- Mint.HTTP.request(node, conn.method, path, headers, body) do
      case answer(conn, node, ref, %{status: nil, response: ""}) do
        {:done, conn, %{status: 200, response: response}} ->
          done.(capture("", body || ""), response)
          conn

        {:done, conn, %{status: status}} when status in 500..599 ->
          StoreDown.report("The code store answered #{status} for #{fleet_id}")
          conn

        {:failed, conn, _answer} ->
          StoreDown.report("The code store stopped answering for #{fleet_id}")
          conn

        {_ended, conn, _answer} ->
          conn
      end
    else
      unreachable ->
        StoreDown.report(
          "The code store could not be reached for #{fleet_id}: #{inspect(unreachable)}"
        )

        refuse(conn, 502, "code_unavailable")
    end
  end

  defp answer(conn, node, ref, answer) do
    case Mint.HTTP.recv(node, 0, Code.config()[:node_timeout_ms]) do
      {:ok, node, parts} ->
        case Enum.reduce_while(parts, {:open, conn, answer}, &part(ref, &1, &2)) do
          {:open, conn, answer} -> answer(conn, node, ref, answer)
          {ended, conn, answer} -> close(node, {ended, conn, answer})
        end

      {:error, node, _reason, _parts} ->
        close(node, {:failed, unanswered(conn), answer})
    end
  end

  defp close(node, ended) do
    Mint.HTTP.close(node)
    ended
  end

  defp unanswered(%Plug.Conn{state: :chunked} = conn), do: conn
  defp unanswered(conn), do: refuse(conn, 502, "code_unavailable")

  defp part(ref, {:status, ref, status}, {:open, conn, answer}),
    do: {:cont, {:open, conn, %{answer | status: status}}}

  # A provisional answer, such as 100 Continue, is the store's alone.
  defp part(ref, {:headers, ref, _headers}, {:open, conn, %{status: status} = answer})
       when status in 100..199,
       do: {:cont, {:open, conn, answer}}

  defp part(ref, {:headers, ref, headers}, {:open, conn, answer}) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        if name in @kept_response, do: put_resp_header(conn, name, value), else: conn
      end)

    {:cont, {:open, send_chunked(conn, answer.status), answer}}
  end

  defp part(ref, {:data, ref, data}, {:open, conn, answer}) do
    case chunk(conn, data) do
      {:ok, conn} -> {:cont, {:open, conn, %{answer | response: capture(answer.response, data)}}}
      {:error, _closed} -> {:halt, {:client_gone, conn, answer}}
    end
  end

  defp part(ref, {:done, ref}, {:open, conn, answer}), do: {:halt, {:done, conn, answer}}
  defp part(_ref, _other, state), do: {:cont, state}

  defp capture(kept, _data) when byte_size(kept) >= @captured, do: kept

  defp capture(kept, data),
    do: kept <> binary_part(data, 0, min(byte_size(data), @captured - byte_size(kept)))
end
