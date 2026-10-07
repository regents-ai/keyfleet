defmodule KeyfleetWeb.Plugs.CodeGateway do
  @moduledoc """
  The only way into the fleets' code (`Keyfleet.Code`). Every request to the
  code host stops here, before anything else the site serves, and reaches the
  code store only once this site knows who sent it and that they hold one of
  the fleet's keys now.

  Git asks at `/<fleet id>.git` for the three things it needs, and nothing
  else is answered: what the repository holds (`info/refs`), a copy
  (`git-upload-pack`) and changes sent (`git-receive-pack`). It signs in with
  a password from `KeyfleetWeb.CodePassword`, under any user name. Each holder
  is checked at most every `access_ttl_ms`; a key changing hands clears the
  fleet's admissions at once.

  What reaches the store carries a pass (`Keyfleet.Code.Pass`) in place of the
  password, with only the headers git's exchange needs. Bodies stream both
  ways, a request's up to `max_pack_bytes`. When the store reports changes
  done, each branch or tag moved is recorded for the fleet's workspace.
  """
  @behaviour Plug

  import Plug.Conn

  alias Keyfleet.Code
  alias Keyfleet.Code.{Pass, ReceivePack}
  alias KeyfleetWeb.{CodePassword, Refusal}

  @services ~w(git-upload-pack git-receive-pack)
  @fleet_id ~r/\A[a-z0-9_]{1,64}\z/

  # Only what git's exchange needs passes either way.
  @kept_request ~w(accept accept-encoding content-encoding content-type git-protocol user-agent)
  @kept_response ~w(cache-control content-encoding content-type expires pragma)

  @chunk 1_000_000
  # Enough of each side of a push to read its commands and the store's report.
  @captured 65_536

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if conn.host == Code.config()[:host], do: conn |> serve() |> halt(), else: conn
  end

  defp serve(conn) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:route, {:ok, fleet_id, need, target}} <- {:route, route(conn)},
         {:password, {:ok, subject, actor}} <- {:password, signed_in(conn, fleet_id)},
         {:holder, {:ok, %{} = holder}} <-
           {:holder, Code.admitted(fleet_id, subject, fn -> Code.holder(actor, fleet_id) end)},
         {:allowed, {:ok, pass}} <- {:allowed, pass(fleet_id, holder, need)},
         {:owner, {:ok, owner}} <- {:owner, Code.owner(fleet_id)} do
      forward(
        conn,
        "/#{owner}/#{fleet_id}/#{target}",
        pass,
        &sent(conn, fleet_id, holder, &1, &2)
      )
    else
      {:route, :error} ->
        refuse(conn, 404, "code_not_found")

      {:password, :error} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="Keyfleet code"))
        |> refuse(401, "code_sign_in")

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

  defp signed_in(conn, fleet_id) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_user, password} -> CodePassword.read(password, fleet_id)
      :error -> :error
    end
  end

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
  defp forward(conn, path, pass, done) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Code.config()[:node])

    headers = [
      {"authorization", "Bearer " <> pass}
      | for({name, value} <- conn.req_headers, name in @kept_request, do: {name, value})
    ]

    body = if conn.method == "POST", do: :stream

    with {:ok, node} <-
           Mint.HTTP.connect(String.to_existing_atom(scheme), host, port,
             mode: :passive,
             protocols: [:http1]
           ),
         {:ok, node, ref} <- Mint.HTTP.request(node, conn.method, path, headers, body) do
      exchange(conn, node, ref, body, done)
    else
      _unreachable -> refuse(conn, 502, "code_unavailable")
    end
  end

  defp exchange(conn, node, ref, body, done) do
    case send_body(conn, node, ref, body) do
      {:ok, conn, node, request} ->
        case answer(conn, node, ref, %{status: nil, response: ""}) do
          {:done, conn, %{status: 200, response: response}} ->
            done.(request, response)
            conn

          {_ended, conn, _answer} ->
            conn
        end

      {:refused, conn, node, status, code} ->
        Mint.HTTP.close(node)
        refuse(conn, status, code)
    end
  end

  defp send_body(conn, node, _ref, nil), do: {:ok, conn, node, ""}
  defp send_body(conn, node, ref, :stream), do: send_body(conn, node, ref, 0, "")

  defp send_body(conn, node, ref, sent, request) do
    case read_body(conn, length: @chunk, read_length: @chunk) do
      {read, data, conn} ->
        sent = sent + byte_size(data)
        request = capture(request, data)

        cond do
          sent > Code.config()[:max_pack_bytes] -> {:refused, conn, node, 413, "code_too_large"}
          read == :more -> stream(conn, node, ref, data, &send_body(&1, &2, ref, sent, request))
          true -> stream(conn, node, ref, data, &finish(&1, &2, ref, request))
        end

      {:error, _reason} ->
        {:refused, conn, node, 400, "invalid_request"}
    end
  end

  defp finish(conn, node, ref, request) do
    case Mint.HTTP.stream_request_body(node, ref, :eof) do
      {:ok, node} -> {:ok, conn, node, request}
      {:error, node, _reason} -> {:refused, conn, node, 502, "code_unavailable"}
    end
  end

  defp stream(conn, node, _ref, "", next), do: next.(conn, node)

  defp stream(conn, node, ref, data, next) do
    case Mint.HTTP.stream_request_body(node, ref, data) do
      {:ok, node} -> next.(conn, node)
      {:error, node, _reason} -> {:refused, conn, node, 502, "code_unavailable"}
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
