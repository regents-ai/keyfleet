defmodule KeyfleetWeb.AgentNotebookFilesTest do
  # Agents make a fleet's notebooks and write their files through their own
  # signed requests here. The hub is a local server that keeps files as the
  # real one does: adding a file at a path already taken, or writing one where
  # a folder is or under a file, is refused with the one conflict the real hub
  # answers for every reason, and each path it answers starts with `/`. A test
  # can set how it answers the next request to a path by a method, once
  # (`answer_next/4`). Like Fly's private addresses, it answers only on IPv6,
  # by name.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys, Notebooks, PairingHelpers, Projects}
  alias Keyfleet.Notebooks.Files
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @notebook "nb-0123456789abcdef"
  @api "/api/v1/agent/fleets/#{@fleet}/projects/general/notebooks"
  @workspace "/api/v1/projects/proj-fleet/notebooks/#{@notebook}/workspace/"
  @jobs "/api/v1/projects/proj-fleet/notebooks/#{@notebook}/jobs"
  @add "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/add"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    files = start_supervised!({Agent, fn -> %{} end})
    test = self()

    hub =
      SignedAgentHelpers.serve_ipv6!(:hub, fn conn, _opts ->
        {:ok, body, conn} = read_body(conn)
        conn = fetch_query_params(conn)
        [pass] = get_req_header(conn, "x-keyfleet-assertion")
        subject = JOSE.JWT.peek_payload(pass).fields["sub"]
        send(test, {:hub, conn.method, conn.request_path, subject, conn.query_params, body})

        case Agent.get_and_update(files, &Map.pop(&1, {:next, conn.method, conn.request_path})) do
          nil -> hub_answer(conn, files, body)
          next -> hub_next(next, conn, files, body)
        end
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))

    @fleet
    |> Projects.project!(Projects.general(), actor: %System{})
    |> Projects.record_space!("proj-fleet", actor: %System{})

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    first = agent!(2)

    # Key 2 takes over the fleet's archived `general`, so its notebooks take work.
    Projects.take_over_project!(@fleet, 2, Projects.general(),
      actor: %Keyfleet.Actors.Human{human_account_id: 1, wallet_addresses: [first.wallet]}
    )

    %{secret: secret, files: files, first: first, second: agent!(3)}
  end

  # Costly failure: agents keeping one shared log lose each other's entries,
  # because one agent's writing replaces another's at the same path.
  test "agents each add files of their own to one notebook, and adding never replaces a file",
       c do
    created =
      post!(c, c.first, "#{@api}/create", %{
        "title" => "Classic #1 pilot log",
        "code" => "import marimo",
        "idempotency_key" => "log-1"
      })

    assert json_response(created, 200) == %{
             "notebook_id" => @notebook,
             "title" => "Classic #1 pilot log",
             "notebook_url" => Notebooks.notebook_url(@fleet, "proj-fleet", @notebook)
           }

    assert last_did(c.first) == :notebook

    first = c.first.subject

    assert_receive {:hub, "POST", "/api/v1/projects/proj-fleet/notebooks", ^first, _query, body}
    assert %{"description" => "", "tags" => []} = Jason.decode!(body)

    files = "#{@api}/#{@notebook}/files/"
    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    assert json_response(post!(c, c.first, files <> "add", entry), 200)["path"] == "/log/a.md"
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "true"}, _body}

    taken = post!(c, c.second, files <> "add", %{entry | "content" => "Second, over the first."})
    assert json_response(taken, 409)["error"]["code"] == "notebook_file_exists"

    assert last_did(c.second) == nil

    own = %{"path" => "log/b.md", "content" => "Second, from the second agent."}
    assert json_response(post!(c, c.second, files <> "add", own), 200)["path"] == "/log/b.md"
    assert last_did(c.second) == :notebook

    listed = json_response(post!(c, c.first, files <> "list", %{"path" => "log"}), 200)
    assert Enum.map(listed["entries"], & &1["path"]) == ["/log/a.md", "/log/b.md"]
    assert listed["cursor"] == nil

    read = &json_response(post!(c, c.second, files <> "read", %{"path" => &1}), &2)
    assert read.("log/a.md", 200)["content"] == "First, from the first agent."

    # Writing a file is how its own writer replaces it.
    post!(c, c.first, files <> "write", %{entry | "content" => "First, corrected."})
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "false"}, _body}
    assert read.("log/a.md", 200)["content"] == "First, corrected."

    # Only a file's maker writes over it.
    over = post!(c, c.second, files <> "write", %{entry | "content" => "Second, over the first."})
    assert json_response(over, 403)["error"]["code"] == "notebooks_maker_only"
    assert read.("log/a.md", 200)["content"] == "First, corrected."

    assert read.("log/none.md", 404)["error"]["code"] == "notebook_file_not_found"
    Agent.update(c.files, &Map.put(&1, "chart.png", <<0xFF, 0xD8, 0xFF>>))
    assert read.("chart.png", 422)["error"]["code"] == "notebook_file_not_text"
    Agent.update(c.files, &Map.put(&1, "big.md", String.duplicate("a", 1024 * 1024 + 1)))
    assert read.("big.md", 422)["error"]["code"] == "notebook_file_too_large"
  end

  # Costly failure: a file added while its maker can't be kept stays as the
  # notebook maker's, and the agent that added it can't change or remove it.
  test "a file whose maker can't be kept is removed again", c do
    # Renamed inside the test's own transaction, so keeping the maker fails the
    # way it does while the database can't be reached; the rename ends with the test.
    prefix = Keyfleet.Repo.default_prefix()
    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.notebook_file_makers RENAME TO makers_away")

    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    added = post!(c, c.first, "#{@api}/#{@notebook}/files/add", entry)

    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.makers_away RENAME TO notebook_file_makers")

    assert json_response(added, 503)["error"]["code"] == "notebooks_unavailable"
    first = c.first.subject
    entries = @workspace <> "entries"
    assert_receive {:hub, "DELETE", ^entries, ^first, %{"path" => "log/a.md"}, _body}
    assert Agent.get(c.files, & &1) == %{}
  end

  # Costly failure: an agent whose add the notebook kept but never answered
  # can't tell whether it landed, so it either loses its entry or adds it twice.
  test "an add the notebook kept without answering is unknown, with a receipt its read settles",
       c do
    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(Notebooks.config(), :hub_timeout_ms, 200)
    )

    answer_next(c, "PUT", "files", :keeps_then_hangs)
    files = "#{@api}/#{@notebook}/files/"
    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    added = post!(c, c.first, files <> "add", entry)

    body = json_response(added, 503)
    assert ContractSchema.response_errors(body, "POST", @add, 503) == []
    [request_id] = get_resp_header(added, "x-request-id")
    sha256 = Files.sha256(entry["content"])

    assert body["error"]["code"] == "notebook_outcome_unknown"

    assert body["error"]["details"] == %{
             "receipt" => %{
               "request_id" => request_id,
               "notebook_id" => @notebook,
               "path" => "log/a.md",
               "sha256" => sha256,
               "bytes" => byte_size(entry["content"])
             },
             "settle" => "notebooks_read_file"
           }

    assert last_did(c.first) == nil

    read = json_response(post!(c, c.first, files <> "read", %{"path" => "log/a.md"}), 200)
    assert read["sha256"] == sha256

    # Sent again, it answers the file it saved, and saves it once.
    first = c.first.subject
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "true"}, _body}
    assert json_response(post!(c, c.first, files <> "add", entry), 200)["path"] == "/log/a.md"
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "true"}, _body}
    refute_received {:hub, "PUT", _path, _subject, _query, _body}
    assert Agent.get(c.files, & &1) == %{"log/a.md" => entry["content"]}
    assert last_did(c.first) == :notebook

    # Kept as the first agent's own: it writes over it, and no one else does.
    over = post!(c, c.second, files <> "write", %{entry | "content" => "Second, over the first."})
    assert json_response(over, 403)["error"]["code"] == "notebooks_maker_only"
    own = post!(c, c.first, files <> "write", %{entry | "content" => "First, corrected."})
    assert json_response(own, 200)["path"] == "/log/a.md"
  end

  test "an add the notebook failed without keeping is unknown, and lands when sent again", c do
    answer_next(c, "PUT", "files", :fails)
    files = "#{@api}/#{@notebook}/files/"
    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}

    failed = post!(c, c.first, files <> "add", entry)
    assert json_response(failed, 503)["error"]["code"] == "notebook_outcome_unknown"

    unread = post!(c, c.first, files <> "read", %{"path" => "log/a.md"})
    assert json_response(unread, 404)["error"]["code"] == "notebook_file_not_found"

    assert json_response(post!(c, c.first, files <> "add", entry), 200)["path"] == "/log/a.md"
    assert Agent.get(c.files, & &1) == %{"log/a.md" => entry["content"]}
  end

  test "a file whose maker can't be kept and whose removal goes unconfirmed is unknown", c do
    prefix = Keyfleet.Repo.default_prefix()
    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.notebook_file_makers RENAME TO makers_away")
    answer_next(c, "DELETE", "entries", :fails)

    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    added = post!(c, c.first, "#{@api}/#{@notebook}/files/add", entry)

    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.makers_away RENAME TO notebook_file_makers")

    body = json_response(added, 503)
    assert body["error"]["code"] == "notebook_outcome_unknown"
    assert body["error"]["details"]["receipt"]["sha256"] == Files.sha256(entry["content"])
    first = c.first.subject
    entries = @workspace <> "entries"
    assert_receive {:hub, "DELETE", ^entries, ^first, %{"path" => "log/a.md"}, _body}
    assert Agent.get(c.files, & &1) == %{"log/a.md" => entry["content"]}
  end

  # Costly failure: an agent told to wait for a path that a folder or a file
  # holds waits for ever.
  test "adding a file where a folder is, or under a file, answers that the path is taken", c do
    Agent.update(c.files, &Map.put(&1, "log/a.md", "First."))

    for path <- ["log", "log/a.md/b.md"] do
      taken =
        post!(c, c.first, "#{@api}/#{@notebook}/files/add", %{"path" => path, "content" => "x"})

      assert json_response(taken, 409)["error"]["code"] == "notebook_file_exists"
    end

    assert Agent.get(c.files, & &1) == %{"log/a.md" => "First."}
  end

  # Costly failure: an agent told a paused path is taken adds its entry
  # somewhere else, and the log loses its order.
  test "an add or write while the notebook can't change files is refused, and nothing is written",
       c do
    files = "#{@api}/#{@notebook}/files/"
    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}

    answer_next(c, "PUT", "files", :paused)
    paused = post!(c, c.first, files <> "add", entry)
    assert json_response(paused, 409)["error"]["code"] == "notebook_writes_paused"
    assert Agent.get(c.files, & &1) == %{}
    assert last_did(c.first) == nil

    assert json_response(post!(c, c.first, files <> "add", entry), 200)["path"] == "/log/a.md"

    answer_next(c, "PUT", "files", :paused)
    paused = post!(c, c.first, files <> "write", %{entry | "content" => "First, corrected."})
    assert json_response(paused, 409)["error"]["code"] == "notebook_writes_paused"
    assert Agent.get(c.files, & &1) == %{"log/a.md" => entry["content"]}
  end

  test "an add the notebook never heard is unavailable, as nothing was written", c do
    {:ok, socket} = :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(Notebooks.config(), :fleets, %{@fleet => "http://localhost:#{port}"})
    )

    added =
      Files.write(@fleet, nil, c.first.subject, "proj-fleet", @notebook, "log/a.md", "x", :add)

    assert added == {:error, :unavailable}
  end

  test "an unknown add answers through /mcp exactly as its signed request does", c do
    oauth = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, oauth) end)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(oauth, :enabled?, true))

    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    answer_next(c, "PUT", "files", :fails)
    http = json_response(post!(c, c.first, "#{@api}/#{@notebook}/files/add", entry), 503)

    answer_next(c, "PUT", "files", :fails)
    where = %{"fleet_id" => @fleet, "project" => "general", "notebook_id" => @notebook}
    called = mcp!(c, c.first, "notebooks_add_file", Map.merge(entry, where))

    assert called.status == 200
    result = Jason.decode!(called.resp_body)["result"]
    assert %{"isError" => true, "content" => [%{"text" => text}]} = result
    over_mcp = Jason.decode!(text)

    assert [over_mcp["error"]["details"]["receipt"]["request_id"]] ==
             get_resp_header(called, "x-request-id")

    assert without_request_id(over_mcp["error"]) == without_request_id(http["error"])
  end

  test "a notebook made for a goal carries the goal's tag, which lists it on the goal's page",
       c do
    made = %{"title" => "Boat count", "code" => "import marimo", "goal" => "goal#19"}

    assert json_response(
             post!(c, c.first, "#{@api}/create", Map.put(made, "idempotency_key", "nb-1")),
             200
           )

    first = c.first.subject
    assert_receive {:hub, "POST", "/api/v1/projects/proj-fleet/notebooks", ^first, _query, body}
    assert Jason.decode!(body)["tags"] == ["goal-19"]

    for goal <- ["goal-19", "task#3", "goal#0", 19] do
      refused =
        post!(
          c,
          c.first,
          "#{@api}/create",
          %{made | "goal" => goal} |> Map.put("idempotency_key", "nb-2")
        )

      assert refused.status in 400..499

      refute_receive {:hub, "POST", "/api/v1/projects/proj-fleet/notebooks", _subject, _query,
                      _body}
    end
  end

  # Costly failure: one agent's job holds everyone's runs, so its maker
  # deleting it stops and loses the others' runs.
  test "each agent's runs go in a job of its own, and each lists its own last run", c do
    runs = "#{@api}/#{@notebook}/runs/start"
    first = c.first.subject
    second = c.second.subject

    # Each notebook as the Docs place lists it, with its description and when
    # it was added, and no run before one is started.
    list = json_response(get!(c, c.first, @api), 200)
    assert ContractSchema.errors(list, "NotebookList") == []

    assert [%{"description" => "", "created_at" => "2026-10-21T09:00:00Z", "last_run" => nil}] =
             list["notebooks"]

    started = post!(c, c.first, runs, %{"idempotency_key" => "run-1"})
    assert json_response(started, 200)["run_id"] == "run_1"
    assert_receive {:hub, "POST", @jobs, ^first, _query, _body}

    again = post!(c, c.first, runs, %{"idempotency_key" => "run-2"})
    assert json_response(again, 200)["run_id"] == "run_2"
    refute_receive {:hub, "POST", @jobs, _subject, _query, _body}

    post!(c, c.second, runs, %{"idempotency_key" => "run-3"})
    assert_receive {:hub, "POST", @jobs, ^second, _query, _body}

    jobs = Agent.get(c.files, & &1["jobs"])
    assert Enum.map(jobs, & &1["created_by"]) == [first, second]
    assert Enum.map(jobs, &length(&1["runs"])) == [2, 1]

    listed =
      &(json_response(get!(c, &1, @api), 200)["notebooks"]
        |> hd()
        |> get_in(["last_run", "run_id"]))

    assert listed.(c.first) == "run_2"
    assert listed.(c.second) == "run_3"
  end

  defp get!(c, agent, path) do
    request = SignedAgentHelpers.sign(agent.signer, c.secret, "www.example.com", "GET", path, nil)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :get, path)
  end

  defp post!(c, agent, path, body) do
    raw = Jason.encode!(body)

    request =
      SignedAgentHelpers.sign(agent.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
  end

  # The same request as a tool call to /mcp, signed by the agent's own key,
  # with no token.
  defp mcp!(c, agent, name, input) do
    raw =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => %{"input" => input}}
      })

    request =
      SignedAgentHelpers.sign(agent.signer, c.secret, "www.example.com", "POST", "/mcp", raw)

    request.headers
    |> Map.drop(["cookie", "authorization"])
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> dispatch(@endpoint, :post, "/mcp", raw)
  end

  # Each request has its own id, so two refusals are compared without it.
  defp without_request_id(error),
    do: update_in(error, ["details", "receipt"], &Map.delete(&1, "request_id"))

  # An agent with a profile, paired with the person who owns Key `token_id`.
  # What the agent did last in the fleet, as its check-in records it.
  defp last_did(agent) do
    check_in = Keyfleet.Agents.get_check_in!(agent.profile_id, @fleet)
    check_in && check_in.last_contribution_kind
  end

  defp agent!(token_id) do
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)
    epoch!(token_id, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate #{token_id}", declared_harness: "local"},
        actor: PairingHelpers.pair_wallet!(wallet)
      )

    %{
      signer: signer,
      wallet: wallet,
      profile_id: profile.id,
      subject: Notebooks.agent_subject(profile.id)
    }
  end

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end

  ## The hub

  # Jobs and their runs are kept under "jobs", newest run first, as the hub
  # lists them.
  defp hub_answer(%Plug.Conn{method: "GET", request_path: @jobs} = conn, files, _body) do
    jobs = for job <- Agent.get(files, &Map.get(&1, "jobs", [])), do: Map.delete(job, "runs")
    json(conn, 200, %{success: true, data: %{items: jobs}})
  end

  defp hub_answer(%Plug.Conn{method: "POST", request_path: @jobs} = conn, files, body) do
    [pass] = get_req_header(conn, "x-keyfleet-assertion")
    maker = JOSE.JWT.peek_payload(pass).fields["sub"]
    jobs = Agent.get(files, &Map.get(&1, "jobs", []))
    job = %{"id" => "job_#{length(jobs) + 1}", "created_by" => maker, "runs" => []}
    job = Map.merge(job, Map.take(Jason.decode!(body), ["name"]))
    Agent.update(files, &Map.put(&1, "jobs", jobs ++ [job]))
    json(conn, 201, %{success: true, data: Map.delete(job, "runs")})
  end

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: @jobs <> "/" <> runs} = conn,
         files,
         _body
       ) do
    [job_id, "runs"] = String.split(runs, "/")

    run =
      Agent.get_and_update(files, fn kept ->
        all = Enum.flat_map(kept["jobs"], & &1["runs"])
        run = %{"run_id" => "run_#{length(all) + 1}", "status" => "queued"}

        {run, %{kept | "jobs" => Enum.map(kept["jobs"], &with_run(&1, job_id, run))}}
      end)

    json(conn, 201, %{success: true, data: run})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @jobs <> "/" <> runs} = conn,
         files,
         _body
       ) do
    [job_id, "runs"] = String.split(runs, "/")
    job = Enum.find(Agent.get(files, & &1["jobs"]), &(&1["id"] == job_id))
    json(conn, 200, %{success: true, data: %{items: Enum.take(job["runs"], 1)}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/notebooks"} = conn,
         _files,
         _body
       ),
       do:
         json(conn, 200, %{
           success: true,
           data: %{
             items: [
               %{id: @notebook, title: "Log", description: "", created_at: "2026-10-21T09:00:00Z"}
             ]
           }
         })

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/notebooks"} = conn,
         _files,
         body
       ) do
    [_key] = get_req_header(conn, "idempotency-key")
    json(conn, 201, %{success: true, data: %{id: @notebook, title: Jason.decode!(body)["title"]}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @workspace <> "entries"} = conn,
         files,
         _body
       ) do
    # No path lists the whole workspace, as a run's record of its files does;
    # the jobs kept beside the files are not files.
    folder = if path = conn.query_params["path"], do: path <> "/", else: ""

    items =
      for {path, content} when is_binary(content) <- Enum.sort(Agent.get(files, & &1)),
          String.starts_with?(path, folder),
          do: item(path, content)

    json(conn, 200, %{success: true, data: %{items: items}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @workspace <> "files"} = conn,
         files,
         _body
       ) do
    case Agent.get(files, &Map.fetch(&1, conn.query_params["path"])) do
      {:ok, content} ->
        send_resp(conn, 200, content)

      :error ->
        json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No such file"}})
    end
  end

  defp hub_answer(
         %Plug.Conn{method: "DELETE", request_path: @workspace <> "entries"} = conn,
         files,
         _body
       ) do
    Agent.update(files, &Map.delete(&1, conn.query_params["path"]))
    json(conn, 200, %{success: true, data: %{}})
  end

  defp hub_answer(
         %Plug.Conn{method: "PUT", request_path: @workspace <> "files"} = conn,
         files,
         body
       ) do
    %{"path" => path, "create" => create} = conn.query_params

    added =
      Agent.get_and_update(files, fn kept ->
        # A folder at the path, or a file where one of its folders would be.
        in_the_way? =
          Enum.any?(kept, fn {kept_path, content} ->
            is_binary(content) and
              (String.starts_with?(kept_path, path <> "/") or
                 String.starts_with?(path, kept_path <> "/"))
          end)

        if in_the_way? or (create == "true" and Map.has_key?(kept, path)),
          do: {false, kept},
          else: {true, Map.put(kept, path, body)}
      end)

    if added,
      do: json(conn, 200, %{success: true, data: item(path, body)}),
      else:
        json(conn, 409, %{success: false, error: %{code: "CONFLICT", message: "already exists"}})
  end

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/members"} = conn,
         _files,
         _body
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  # A run records the code it ran from, so starting one reads the notebook.
  defp hub_answer(
         %Plug.Conn{
           method: "GET",
           request_path: "/api/v1/projects/proj-fleet/notebooks/#{@notebook}/content"
         } = conn,
         _files,
         _body
       ),
       do: json(conn, 200, %{success: true, data: %{code: "import marimo"}})

  defp hub_answer(conn, _files, _body), do: json(conn, 200, %{success: true, data: %{}})

  # The hub keeps the file, then answers after Keyfleet has stopped waiting.
  defp hub_next(:keeps_then_hangs, conn, files, body) do
    path = conn.query_params["path"]
    Agent.update(files, &Map.put(&1, path, body))
    Process.sleep(600)
    json(conn, 200, %{success: true, data: item(path, body)})
  end

  # The hub fails before changing anything.
  defp hub_next(:fails, conn, _files, _body),
    do: json(conn, 502, %{success: false, error: %{code: "BAD_GATEWAY", message: "Upstream"}})

  # A member's live session can still save, so the hub changes no file.
  defp hub_next(:paused, conn, _files, _body),
    do:
      json(conn, 409, %{
        success: false,
        error: %{
          code: "CONFLICT",
          message:
            "Workspace files cannot be changed while a persistent edit session can still save"
        }
      })

  # How the hub answers the next request by `method` to `path` in the
  # notebook's workspace, once.
  defp answer_next(c, method, path, answer),
    do: Agent.update(c.files, &Map.put(&1, {:next, method, @workspace <> path}, answer))

  defp with_run(%{"id" => job_id} = job, job_id, run), do: %{job | "runs" => [run | job["runs"]]}
  defp with_run(job, _job_id, _run), do: job

  defp item(path, content),
    do: %{
      path: "/" <> path,
      name: Path.basename(path),
      kind: "file",
      size: byte_size(content),
      modified_at: 1
    }

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
