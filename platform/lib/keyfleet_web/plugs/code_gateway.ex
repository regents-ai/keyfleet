defmodule KeyfleetWeb.Plugs.CodeGateway do
  @moduledoc """
  The only way into the fleets' code (`Keyfleet.Code`). Every request to the
  code host stops here, before anything else the site serves, and reaches the
  code store only once this site knows who sent it and that they hold one of
  the fleet's keys now.

  Git asks at `/<repository>.git`, a project's repository
  (`Keyfleet.Projects.Project`), for the three things it needs, and nothing
  else is answered, but for a browser opening `/<repository>.git` itself, which
  is sent to the project's code on the site: what the repository holds
  (`info/refs`), a copy (`git-upload-pack`) and changes sent
  (`git-receive-pack`). Who sent it, checked against the fleet the
  repository's name begins with, before anyone learns whether that project
  is there:

    * An agent signs every request with its own sign-in (SIWA, as on
      `/api/v1/agent`): its method, its path with the query, and the
      `content-digest` it declares for its exact body, an empty one included.
      The sign-in server checks the signature before any of the body is read.
      The agent is then let in by what its own wallet holds or by its pairing
      with a holder, checked on every request.
    * A person signs in with a password from `KeyfleetWeb.CodePassword`, under
      any user name, checked at most every `access_ttl_ms`.

  Only then is the body read, into a file as it arrives, never held whole: at
  most `max_pack_bytes`, each read waiting at most `body_idle_ms` and the whole
  body at most `body_timeout_ms`, so a sender trickling bytes is cut off. An
  agent's body reaches the store only if it is the one its signature declared;
  any other is refused and its file deleted, and nothing was sent to the store.
  Once the body is in, the key is checked again and only then is the store's
  pass made, so a body that arrives slowly still carries a pass that holds,
  and a key that changed hands meanwhile is refused.

  A key changing hands clears the fleet's admissions at once.

  What reaches the store carries a pass (`Keyfleet.Code.Pass`) in place of
  any sign-in, with only the headers git's exchange needs. The store's answer
  streams back. Each push spends `:code_pushes` for the wallet it is sent as
  (`Keyfleet.Limits`), before its body is read. When the store reports changes
  done, each branch or tag moved, up to `@recorded` of them, is recorded for
  the fleet's workspace, under the project and the key and, for an agent, the
  agent too. A store that cannot be reached, stops mid-exchange, answers with
  a fault of its own or refuses the pass is saved with the site's errors
  (`Keyfleet.Code.StoreDownError`).
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias Keyfleet.{Code, Limits, Projects}
  alias Keyfleet.Code.{Pass, ReceivePack, RecordsDownError, StoreDownError}
  alias Keyfleet.Projects.Project
  alias KeyfleetWeb.{CodePassword, Refusal}
  alias KeyfleetWeb.Plugs.SignedAgent

  @services ~w(git-upload-pack git-receive-pack)

  # Only what git's exchange needs passes either way.
  @kept_request ~w(accept accept-encoding content-encoding content-type git-protocol user-agent)
  @kept_response ~w(cache-control content-encoding content-type expires pragma)

  # Enough of each side of a push to read its commands and the store's report.
  @captured 65_536
  # The most branches and tags one push records; a push of more (`--all`,
  # `--tags`) records the first of them.
  @recorded 20

  # How much of a body is read, written and sent at a time.
  @piece 65_536

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
      |> refuse(503, "not_open_yet")
    end
  end

  # A browser opening a repository's address, as its workspace shows it, is
  # sent to the project's code on the site.
  defp serve_open(%Plug.Conn{method: "GET", path_info: [address]} = conn) do
    with {:ok, repository, fleet_id} <- repository(address),
         true <- fleet_id in Keyfleet.Fleets.catalog_ids() do
      conn
      |> put_resp_header(
        "location",
        KeyfleetWeb.Endpoint.url() <> Code.files_path(fleet_id, repository, "")
      )
      |> send_resp(302, "")
    else
      _other -> refuse(conn, 404, "code_not_found")
    end
  end

  # The body's path is the one Plug.Upload.random_file/1 made, never the sender's.
  # sobelow_skip ["Traversal.FileModule"]
  defp serve_open(conn) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:route, {:ok, repository, fleet_id, need, target}} <- {:route, route(conn)},
         {:signed_in, {:ok, conn, subject, actor}} <- {:signed_in, identify(conn, fleet_id)},
         {:holder, {:ok, %{} = holder}} <-
           {:holder, reported(fleet_id, current_holder(fleet_id, subject, actor))},
         {:allowed, :ok} <- {:allowed, allowed(holder, need)},
         {:project, {:ok, %Project{} = project}} <- {:project, project(repository)},
         {:owner, {:ok, owner}} <- {:owner, Code.owner(repository)},
         {:pushes, :ok} <- {:pushes, spend_push(conn, fleet_id, holder)},
         {:body, {:ok, conn, body}} <- {:body, spool(conn)} do
      check = fn -> reported(fleet_id, current_holder(fleet_id, subject, actor)) end

      try do
        send_checked(conn, project, "/#{owner}/#{repository}/#{target}", need, check, body, actor)
      after
        File.rm!(body.path)
      end
    else
      refused -> refused(conn, refused)
    end
  end

  # A body may take far longer to arrive than a pass lasts, and the key may
  # change hands meanwhile, so the key is checked again once the body is in
  # and the pass is made then.
  defp send_checked(conn, project, path, need, check, body, actor) do
    with {:holder, {:ok, %{} = holder}} <- {:holder, check.()},
         {:allowed, :ok} <- {:allowed, allowed(holder, need)} do
      forward(conn, project.repository, path, pass(project.repository, holder, need), body, fn
        response -> sent(conn, project, holder, actor, body.head, response)
      end)
    else
      refused -> refused(conn, refused)
    end
  end

  defp refused(conn, {:route, :error}), do: refuse(conn, 404, "code_not_found")
  defp refused(conn, {:project, {:ok, nil}}), do: refuse(conn, 404, "code_not_found")
  defp refused(conn, {:project, {:error, _error}}), do: refuse(conn, 503, "code_unavailable")
  defp refused(_conn, {:body, {:too_large, conn}}), do: refuse(conn, 413, "code_too_large")
  defp refused(_conn, {:body, {:error, conn}}), do: refuse(conn, 400, "invalid_request")

  defp refused(_conn, {:body, {:not_signed, conn}}),
    do: refuse(conn, 400, "code_body_not_signed")

  defp refused(_conn, {:signed_in, {:refused, conn}}), do: conn
  defp refused(conn, {:holder, {:ok, nil}}), do: refuse(conn, 403, "code_not_holder")
  defp refused(conn, {:holder, {:error, _error}}), do: refuse(conn, 503, "code_catching_up")
  defp refused(conn, {:allowed, :restricted}), do: refuse(conn, 403, "code_edits_restricted")

  defp refused(conn, {:pushes, {:limited, seconds}}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> refuse(429, "code_pushes_limit_reached")
  end

  defp refused(conn, {:owner, {:setting_up, seconds}}) do
    # The next try, and a minute for it to finish.
    wait = seconds + 60

    conn
    |> put_resp_header("retry-after", Integer.to_string(wait))
    |> refuse(503, Refusal.code_setting_up(wait))
  end

  defp refused(conn, {:owner, :setup_restarted}) do
    conn
    |> put_resp_header("retry-after", "180")
    |> refuse(503, "code_setup_restarted")
  end

  defp refused(conn, {:owner, {:error, _error}}), do: refuse(conn, 503, "code_unavailable")

  # A key that could not be checked is saved with the site's errors; the sender
  # is told to try again shortly.
  defp reported(fleet_id, {:error, error} = failed) do
    RecordsDownError.report("Who holds a key of #{fleet_id} could not be read: #{inspect(error)}")
    failed
  end

  defp reported(_fleet_id, found), do: found

  defp current_holder(fleet_id, _subject, %Keyfleet.Actors.Agent{} = actor),
    do: Code.holder(actor, fleet_id)

  defp current_holder(fleet_id, subject, actor),
    do: Code.admitted(fleet_id, subject, fn -> Code.holder(actor, fleet_id) end)

  # Each push spends the allowance of the wallet it is sent as in the fleet
  # (`Keyfleet.Keys.identity/2`), so a person and the agents pushing as their
  # Key share one; copying the code spends none.
  defp spend_push(
         %Plug.Conn{method: "POST", path_info: [_repository, "git-receive-pack"]},
         fleet_id,
         holder
       ),
       do: Limits.admit(:code_pushes, {fleet_id, holder.wallet})

  defp spend_push(_conn, _fleet_id, _holder), do: :ok

  # When the store took a push, what it moved is recorded under the holder,
  # and an agent's push as its latest contribution.
  defp sent(
         %Plug.Conn{method: "POST", path_info: [_repository, "git-receive-pack"]},
         project,
         holder,
         actor,
         request,
         response
       ) do
    case request |> ReceivePack.updates(response) |> Enum.take(@recorded) do
      [] ->
        :ok

      updates ->
        Code.record_pushes(project.fleet_id, project.name, holder, updates)
        Keyfleet.Agents.record_contribution(actor, project.fleet_id, :code)
    end
  end

  defp sent(_conn, _project, _holder, _actor, _request, _response), do: :ok

  ## What is asked

  defp route(%Plug.Conn{method: "GET", path_info: [address, "info", "refs"]} = conn) do
    conn = fetch_query_params(conn)

    with {:ok, repository, fleet_id} <- repository(address),
         %{"service" => service} when service in @services <- conn.query_params do
      {:ok, repository, fleet_id, need(service), "info/refs?service=" <> service}
    else
      _other -> :error
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: [address, service]})
       when service in @services do
    with {:ok, repository, fleet_id} <- repository(address),
         do: {:ok, repository, fleet_id, need(service), service}
  end

  defp route(_conn), do: :error

  defp repository(address) do
    repository = String.replace_suffix(address, ".git", "")

    with true <- repository <> ".git" == address,
         {:ok, fleet_id} <- Code.repository_fleet(repository) do
      {:ok, repository, fleet_id}
    else
      _other -> :error
    end
  end

  defp project(repository),
    do: Projects.project_of_repository(repository, actor: %Keyfleet.Actors.System{})

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
    conn
    |> Siwa.AgentAuthPlug.call(
      client: Keyfleet.SiwaBroker,
      hooks: __MODULE__,
      audience: "keyfleet",
      query: :signed,
      body: :declared
    )
    |> agent()
  end

  defp agent(%Plug.Conn{halted: true} = conn), do: {:refused, conn}
  defp agent(%Plug.Conn{assigns: %{agent_actor: actor}} = conn), do: {:ok, conn, nil, actor}

  defp identify_person(conn, fleet_id) do
    with {_user, password} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, subject, actor} <- CodePassword.read(password, fleet_id) do
      {:ok, conn, subject, actor}
    else
      :error ->
        {:refused,
         conn
         |> put_resp_header("www-authenticate", ~s(Basic realm="Keyfleet code"))
         |> refuse(401, "code_sign_in")}
    end
  end

  ## The body

  # The body is written to a file as it arrives. A sender still sending when
  # `body_timeout_ms` is up is cut off there, even one trickling a byte at a
  # time inside a single read.
  # sobelow_skip ["Traversal.FileModule"]
  defp spool(conn) do
    {:ok, path} = Plug.Upload.random_file("keyfleet-code")
    {:ok, deadline} = :timer.kill_after(Code.config()[:body_timeout_ms])
    file = File.open!(path, [:write, :raw, :binary])

    spooled =
      try do
        conn
        |> fill(file, %{path: path, size: 0, sha256: :crypto.hash_init(:sha256), head: ""})
        |> declared()
      after
        File.close(file)
        :timer.cancel(deadline)
      end

    # A refused body's file goes at once.
    with {_refused, _conn} <- spooled, do: File.rm!(path)
    spooled
  end

  defp fill(conn, file, body) do
    case read_body(conn,
           length: @piece,
           read_length: @piece,
           read_timeout: Code.config()[:body_idle_ms]
         ) do
      {:error, _reason} -> {:error, conn}
      {more, data, conn} -> piece(conn, file, more, data, body)
    end
  end

  defp piece(conn, file, more, data, body) do
    body = %{
      body
      | size: body.size + byte_size(data),
        sha256: :crypto.hash_update(body.sha256, data),
        head: capture(body.head, data)
    }

    cond do
      body.size > Code.config()[:max_pack_bytes] ->
        {:too_large, conn}

      more == :more ->
        :ok = IO.binwrite(file, data)
        fill(conn, file, body)

      true ->
        :ok = IO.binwrite(file, data)
        {:ok, conn, %{body | sha256: :crypto.hash_final(body.sha256)}}
    end
  end

  # An agent's body must be the one its signature declared; a person's has
  # no declaration.
  defp declared({:ok, %Plug.Conn{assigns: %{siwa_body_digest: digest}} = conn, body} = spooled) do
    if Siwa.AgentAuthPlug.declared_body_matches?(body.sha256, digest),
      do: spooled,
      else: {:not_signed, conn}
  end

  defp declared(spooled), do: spooled

  # The shared plug has already refused a repeated signed header and a body
  # read before it; nothing else is checked before the sign-in server.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(_conn, _headers), do: {:ok, nil}

  # Only who sent it is checked here; whether they may use the code comes next.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context), do: SignedAgent.accept_agent(conn, data)

  # Every refusal on the code address is the one plain shape below, a sign-in
  # refused included.
  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, metadata) do
    {status, body} = SignedAgent.refusal(conn, metadata)
    conn |> refuse(status, body) |> halt()
  end

  # A key whose edits a vote restricted may still copy the code.
  defp allowed(%{restricted?: true}, :push), do: :restricted
  defp allowed(_holder, _need), do: :ok

  defp pass(repository, %{restricted?: true}, :read), do: Pass.read(repository)
  defp pass(repository, %{wallet: wallet}, _need), do: Pass.push(repository, wallet)

  # Git shows a plain-text answer to the person running it, and the signing
  # helper reads the same.
  defp refuse(conn, status, code) when is_binary(code),
    do: refuse(conn, status, Refusal.body(code))

  defp refuse(conn, status, %{error: %{message: message, hint: hint}}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message <> "\n" <> hint <> "\n")
  end

  ## Forwarding

  # `done` is told the start of the answer once the store has answered in
  # full and the answer reached the client.
  defp forward(conn, repository, path, pass, body, done) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Code.config()[:node])

    headers = [
      {"authorization", "Bearer " <> pass}
      | for({name, value} <- conn.req_headers, name in @kept_request, do: {name, value})
    ]

    {headers, request_body} =
      if conn.method == "POST",
        do: {[{"content-length", Integer.to_string(body.size)} | headers], :stream},
        else: {headers, nil}

    with {:ok, node} <-
           Mint.HTTP.connect(String.to_existing_atom(scheme), host, port,
             mode: :passive,
             protocols: [:http1],
             # The store's private Flycast address has only an IPv6 record.
             transport_opts: [inet6: true]
           ),
         {:ok, node, ref} <- Mint.HTTP.request(node, conn.method, path, headers, request_body),
         {:ok, node} <- stream(node, ref, request_body, body) do
      case answer(conn, node, ref, %{status: nil, response: ""}) do
        {:done, conn, %{status: 200, response: response}} ->
          done.(response)
          conn

        {:done, conn, %{status: status}} when status in 500..599 ->
          StoreDownError.report("The code store answered #{status} for #{repository}")
          conn

        # Only a pass this site made reaches the store, so its refusal is a fault.
        {:done, conn, %{status: status}} when status in [401, 403] ->
          StoreDownError.report("The code store refused the pass for #{repository} (#{status})")
          conn

        {:failed, conn, _answer} ->
          StoreDownError.report("The code store stopped answering for #{repository}")
          conn

        {_ended, conn, _answer} ->
          conn
      end
    else
      unreachable ->
        StoreDownError.report(
          "The code store could not be reached for #{repository}: #{inspect(unreachable)}"
        )

        refuse(conn, 502, "code_unavailable")
    end
  end

  # The checked body goes to the store from its file, a piece at a time.
  defp stream(node, _ref, nil, _body), do: {:ok, node}

  # sobelow_skip ["Traversal.FileModule"]
  defp stream(node, ref, :stream, body) do
    body.path
    |> File.stream!(@piece)
    |> Enum.reduce_while({:ok, node}, fn piece, {:ok, node} ->
      case Mint.HTTP.stream_request_body(node, ref, piece) do
        {:ok, node} -> {:cont, {:ok, node}}
        failed -> {:halt, failed}
      end
    end)
    |> case do
      {:ok, node} -> Mint.HTTP.stream_request_body(node, ref, :eof)
      failed -> failed
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
