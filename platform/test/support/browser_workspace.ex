defmodule Keyfleet.BrowserWorkspace do
  @moduledoc """
  A fleet's whole workspace for the browser tests. Called on the browser test
  server's own node, `start!/1` runs the fleet's work graph, with its Python
  host writing a fresh log, and a stand-in for its notebook hub, so a spec
  walks a goal from its first task through a notebook, a push of code and a
  second member's review, the way members and their agents do on the site.

  The stand-in hub keeps what it is sent while the server runs, as the real
  one does for the requests this site makes: notebooks, their authors and
  code, each notebook's workspace files with their ETags, jobs and their
  runs. A run has finished
  the first time it is read again, and its page is a short one of its own.
  """

  alias Keyfleet.Graph.{Projector, Projectors, Writer}
  alias Keyfleet.Projects

  @project "proj-0123456789abcdef"

  @doc """
  Starts the fleet's work graph and its notebook hub, in a process of their
  own that lives as long as the node does.
  """
  def start!(fleet_id) do
    caller = self()

    spawn(fn ->
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "keyfleet_browser_graph_#{System.unique_integer([:positive])}"
        )

      opts = [fleets: [fleet_id], data_dir: data_dir, restart_min: 20, restart_max: 200]

      {:ok, _graph} =
        Supervisor.start_link(
          [
            {Keyfleet.Graph.Supervisor, opts},
            {Projectors, [catch_up_interval: 60_000] ++ opts}
          ],
          strategy: :one_for_one
        )

      send(caller, :started)
      Process.sleep(:infinity)
    end)

    receive do
      :started -> :ok
    end

    await(fn -> match?({:ok, _}, Writer.request(fleet_id, "hello", %{})) end)
    {:ok, %{"result" => %{"run_id" => log_id}}} = Writer.request(fleet_id, "hello", %{})
    Projector.await(fleet_id, log_id, 0)

    start_hub!(fleet_id)
  end

  defp start_hub!(fleet_id) do
    caller = self()

    spawn(fn ->
      {:ok, state} =
        Agent.start_link(fn -> %{notebooks: [], code: %{}, files: %{}, jobs: %{}} end)

      plug = fn conn, _opts -> answer(conn, state) end

      {:ok, server} =
        Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      send(caller, {:hub, "http://127.0.0.1:#{port}"})
      Process.sleep(:infinity)
    end)

    hub =
      receive do
        {:hub, hub} -> hub
      end

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    fleets = Map.put(notebooks[:fleets], fleet_id, hub)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, fleets))

    fleet_id
    |> Projects.project!(Projects.general(), actor: %Keyfleet.Actors.System{})
    |> Projects.record_space!(@project, actor: %Keyfleet.Actors.System{})

    :ok
  end

  defp await(ready?, tries \\ 300) do
    cond do
      ready?.() -> :ok
      tries == 0 -> raise "the work graph did not start"
      true -> Process.sleep(100) && await(ready?, tries - 1)
    end
  end

  ## The stand-in hub

  defp answer(conn, state) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    conn = Plug.Conn.fetch_query_params(conn)
    [pass] = Plug.Conn.get_req_header(conn, "x-keyfleet-assertion")
    subject = JOSE.JWT.peek_payload(pass).fields["sub"]
    route(conn.method, conn.path_info, conn, %{state: state, subject: subject, body: body})
  end

  defp route("POST", ["api", "v1", "projects", @project, "members"], conn, _request),
    do: json(conn, 201, %{})

  defp route("DELETE", ["api", "v1", "admin", "users", _user, "suspension"], conn, _request),
    do: json(conn, 200, %{})

  # A tag lists the notebooks tagged with it, or with a tag under it.
  defp route("GET", ["api", "v1", "projects", @project, "notebooks"], conn, request) do
    notebooks = Agent.get(request.state, & &1.notebooks)

    items =
      case conn.query_params do
        %{"tag" => tag} ->
          Enum.filter(notebooks, fn notebook ->
            Enum.any?(notebook.tags, &(&1 == tag or String.starts_with?(&1, tag <> "/")))
          end)

        _all ->
          notebooks
      end

    json(conn, 200, %{items: Enum.map(items, &Map.delete(&1, :meta))})
  end

  defp route("POST", ["api", "v1", "projects", @project, "notebooks"], conn, request) do
    %{"title" => title} = fields = Jason.decode!(request.body)
    now = DateTime.to_iso8601(DateTime.utc_now())

    notebook = %{
      id: "nb-" <> random(16),
      title: title,
      description: fields["description"] || "",
      tags: fields["tags"] || [],
      created_at: now,
      updated_at: now,
      last_run_at: nil,
      meta: %{author: request.subject}
    }

    Agent.update(request.state, fn state ->
      %{
        state
        | notebooks: [notebook | state.notebooks],
          code: Map.put(state.code, notebook.id, fields["code"] || "")
      }
    end)

    json(conn, 201, notebook)
  end

  defp route(
         "GET",
         ["api", "v1", "projects", @project, "notebooks", id, "content"],
         conn,
         request
       ) do
    case Agent.get(request.state, &Map.fetch(&1.code, id)) do
      {:ok, code} -> json(conn, 200, %{code: code})
      :error -> not_found(conn)
    end
  end

  defp route("GET", ["api", "v1", "projects", @project, "notebooks", id], conn, request) do
    case Enum.find(Agent.get(request.state, & &1.notebooks), &(&1.id == id)) do
      nil ->
        not_found(conn)

      notebook ->
        json(conn, 200, %{
          meta:
            notebook
            |> Map.merge(notebook.meta)
            |> Map.delete(:meta)
            |> Map.put(:status, "active")
        })
    end
  end

  defp route(
         method,
         ["api", "v1", "projects", @project, "notebooks", id, "workspace", what],
         conn,
         request
       ),
       do: workspace(method, what, id, conn, request)

  defp route(
         method,
         ["api", "v1", "projects", @project, "notebooks", id, "jobs" | rest],
         conn,
         request
       ),
       do: jobs(method, rest, id, conn, request)

  defp route(_method, _path, conn, _request), do: not_found(conn)

  defp workspace("GET", "entries", id, conn, request) do
    folder = String.trim_leading(conn.query_params["path"] || "", "/")
    prefix = if folder == "", do: "", else: folder <> "/"

    items =
      for {path, content} <- Enum.sort(files(request, id)),
          String.starts_with?(path, prefix),
          not String.contains?(String.replace_prefix(path, prefix, ""), "/"),
          do: %{
            path: "/" <> path,
            name: Path.basename(path),
            kind: "file",
            size: byte_size(content),
            modified_at: 1
          }

    json(conn, 200, %{items: items})
  end

  # A file's ETag is its content's hash, as the hub's file store makes it.
  defp workspace("GET", "files", id, conn, request) do
    case Map.fetch(files(request, id), conn.query_params["path"]) do
      {:ok, content} -> conn |> etag(content) |> Plug.Conn.send_resp(200, content)
      :error -> not_found(conn)
    end
  end

  # A write with If-Match lands only while the file still has that ETag.
  defp workspace("PUT", "files", id, conn, request) do
    %{"path" => path, "create" => create} = conn.query_params
    if_match = conn |> Plug.Conn.get_req_header("if-match") |> List.first()

    written =
      Agent.get_and_update(request.state, fn state ->
        kept = Map.get(state.files, id, %{})

        cond do
          create == "true" and Map.has_key?(kept, path) ->
            {:conflict, state}

          if_match != nil and not Map.has_key?(kept, path) ->
            {:not_found, state}

          if_match != nil and if_match != quoted(kept[path]) ->
            {{:changed, kept[path]}, state}

          true ->
            {:ok, put_in(state, [:files, id], Map.put(kept, path, request.body))}
        end
      end)

    case written do
      :ok ->
        conn
        |> etag(request.body)
        |> json(200, %{path: "/" <> path, kind: "file", size: byte_size(request.body)})

      :conflict ->
        json(conn, 409, %{code: "CONFLICT", message: "already exists"}, false)

      :not_found ->
        not_found(conn)

      {:changed, current} ->
        conn
        |> etag(current)
        |> json(412, %{code: "PRECONDITION_FAILED", message: "changed since read"}, false)
    end
  end

  defp workspace("DELETE", "entries", id, conn, request) do
    path = conn.query_params["path"]

    Agent.update(
      request.state,
      &update_in(&1, [:files, id], fn kept -> Map.delete(kept || %{}, path) end)
    )

    json(conn, 200, %{})
  end

  defp workspace(_method, _what, _id, conn, _request), do: not_found(conn)

  defp jobs("GET", [], id, conn, request),
    do: json(conn, 200, %{items: Enum.map(jobs_of(request, id), &Map.delete(&1, "runs"))})

  defp jobs("POST", [], id, conn, request) do
    job = %{
      "id" => "job_" <> random(8),
      "name" => Jason.decode!(request.body)["name"],
      "created_by" => request.subject,
      "runs" => []
    }

    Agent.update(request.state, &update_in(&1, [:jobs, id], fn jobs -> (jobs || []) ++ [job] end))
    json(conn, 201, Map.delete(job, "runs"))
  end

  defp jobs("POST", [job_id, "runs"], id, conn, request) do
    run = %{
      "run_id" => "run_" <> random(26, ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"),
      "status" => "queued",
      "triggered_by" => request.subject
    }

    update_job(request, id, job_id, &%{&1 | "runs" => [run | &1["runs"]]})
    json(conn, 201, run)
  end

  defp jobs("GET", [job_id, "runs"], id, conn, request) do
    case find_job(request, id, job_id) do
      nil -> not_found(conn)
      job -> json(conn, 200, %{items: Enum.take(job["runs"], 1)})
    end
  end

  # A run read again has finished.
  defp jobs("GET", [job_id, "runs", run_id], id, conn, request) do
    finish = fn job -> %{job | "runs" => Enum.map(job["runs"], &finished(&1, run_id))} end

    with %{} <- find_run(request, id, job_id, run_id),
         :ok <- update_job(request, id, job_id, finish) do
      json(conn, 200, find_run(request, id, job_id, run_id))
    else
      _none -> not_found(conn)
    end
  end

  defp jobs("GET", [job_id, "runs", run_id, "html"], id, conn, request) do
    case find_run(request, id, job_id, run_id) do
      %{"status" => "succeeded"} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.put_resp_header("x-marimohub-run-id", run_id)
        |> Plug.Conn.put_resp_header(
          "x-marimohub-captured-at",
          DateTime.to_iso8601(DateTime.utc_now())
        )
        |> Plug.Conn.send_resp(200, "<html><body><p>42</p></body></html>")

      _none ->
        not_found(conn)
    end
  end

  defp jobs(_method, _rest, _id, conn, _request), do: not_found(conn)

  defp files(request, id), do: Agent.get(request.state, &Map.get(&1.files, id, %{}))
  defp jobs_of(request, id), do: Agent.get(request.state, &Map.get(&1.jobs, id, []))
  defp find_job(request, id, job_id), do: Enum.find(jobs_of(request, id), &(&1["id"] == job_id))

  defp find_run(request, id, job_id, run_id) do
    with %{"runs" => runs} <- find_job(request, id, job_id),
         do: Enum.find(runs, &(&1["run_id"] == run_id))
  end

  defp update_job(request, id, job_id, change) do
    Agent.update(request.state, fn state ->
      jobs = Enum.map(Map.get(state.jobs, id, []), &changed(&1, job_id, change))
      put_in(state, [:jobs, id], jobs)
    end)
  end

  defp changed(%{"id" => job_id} = job, job_id, change), do: change.(job)
  defp changed(job, _job_id, _change), do: job

  defp finished(%{"run_id" => run_id} = run, run_id), do: %{run | "status" => "succeeded"}
  defp finished(run, _run_id), do: run

  defp random(length, alphabet \\ ~c"0123456789abcdefghijklmnopqrstuvwxyz"),
    do: for(_ <- 1..length, into: "", do: <<Enum.random(alphabet)>>)

  defp not_found(conn), do: json(conn, 404, %{code: "NOT_FOUND", message: "Not found"}, false)

  defp etag(conn, content), do: Plug.Conn.put_resp_header(conn, "etag", quoted(content))

  defp quoted(content),
    do: ~s("#{:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)}")

  defp json(conn, status, data, success \\ true) do
    body = if success, do: %{success: true, data: data}, else: %{success: false, error: data}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
