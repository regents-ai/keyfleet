defmodule KeyfleetWeb.AgentNotebookFilesTest do
  # Agents make a fleet's notebooks and write their files through their own
  # signed requests here. The hub is a local server that keeps files as the
  # real one does: adding a file at a path already taken, or writing one where
  # a folder is or under a file, is refused with the one conflict the real hub
  # answers for every reason, and each path it answers starts with `/`. Each
  # file has an ETag, its content's hash, and a write naming one with
  # If-Match lands only while the file still has it, else 412 with the file's
  # ETag now, as the real hub's file store answers. A test
  # can set how it answers the next request to a path by a method, once
  # (`answer_next/4`). Like Fly's private addresses, it answers only on IPv6,
  # by name.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys, Notebooks, PairingHelpers, Projects}
  alias Keyfleet.Notebooks.Files
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @notebook "nb-0123456789abcdef"
  @api "/api/v1/agent/fleets/#{@fleet}/projects/general/notebooks"
  @space "proj-0123456789abcdef"
  @notebooks "/api/v1/projects/#{@space}/notebooks"
  @workspace "#{@notebooks}/#{@notebook}/workspace/"
  @jobs "#{@notebooks}/#{@notebook}/jobs"
  @add "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/add"
  @write "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/write"

  setup do
    # A task is read in the workspace's own snapshot, which the sandbox holds.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

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
    |> Projects.record_space!(@space, actor: %System{})

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
             "notebook_url" => Notebooks.notebook_url(@fleet, @space, @notebook)
           }

    assert last_did(c.first) == :notebook

    first = c.first.subject

    assert_receive {:hub, "POST", @notebooks, ^first, _query, body}
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
    first_read = read.("log/a.md", 200)
    assert first_read["content"] == "First, from the first agent."

    # Writing a file is how its own writer replaces it.
    corrected =
      Map.merge(entry, %{
        "content" => "First, corrected.",
        "expected_revision" => first_read["revision"]
      })

    written = json_response(post!(c, c.first, files <> "write", corrected), 200)
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "false"}, _body}
    assert %{"content" => "First, corrected.", "revision" => revision} = read.("log/a.md", 200)
    assert written["revision"] == revision

    # Only a file's maker writes over it.
    over =
      post!(c, c.second, files <> "write", %{
        corrected
        | "content" => "Second, over the first.",
          "expected_revision" => revision
      })

    assert json_response(over, 403)["error"]["code"] == "notebooks_maker_only"
    assert read.("log/a.md", 200)["content"] == "First, corrected."

    assert read.("log/none.md", 404)["error"]["code"] == "notebook_file_not_found"
    Agent.update(c.files, &Map.put(&1, "chart.png", <<0xFF, 0xD8, 0xFF>>))
    assert read.("chart.png", 422)["error"]["code"] == "notebook_file_not_text"
    Agent.update(c.files, &Map.put(&1, "big.md", String.duplicate("a", 1024 * 1024 + 1)))
    assert read.("big.md", 422)["error"]["code"] == "notebook_file_too_large"
  end

  # Costly failure: two agents read a file, both change it, and the second
  # write silently replaces the first, so the first agent's work is lost.
  for path <- ["log/a.md", "notebook.py", "pyproject.toml"] do
    test "of two writes over the revision both read, #{path} keeps one and the other is refused",
         c do
      path = unquote(path)
      # The notebook's creator unlocked it, so both agents write any of its files.
      Keyfleet.Notebooks.Setting
      |> Ash.Changeset.for_create(
        :switch,
        %{fleet_id: @fleet, notebook_id: @notebook, unlocked: true},
        actor: %System{}
      )
      |> Ash.create!()

      Agent.update(c.files, &Map.put(&1, path, "As it was."))
      files = "#{@api}/#{@notebook}/files/"

      read = fn agent ->
        json_response(post!(c, agent, files <> "read", %{"path" => path}), 200)
      end

      %{"revision" => revision} = read.(c.first)
      assert read.(c.second)["revision"] == revision

      [first, second] =
        [{c.first, "From the first agent."}, {c.second, "From the second agent."}]
        |> Task.async_stream(fn {agent, content} ->
          write = %{"path" => path, "content" => content, "expected_revision" => revision}
          post!(c, agent, files <> "write", write)
        end)
        |> Enum.map(fn {:ok, conn} -> conn end)

      # Exactly one lands; the other is told the revision the file has now.
      assert Enum.sort([first.status, second.status]) == [200, 409]
      [landed, refused] = Enum.sort_by([first, second], & &1.status)
      saved = json_response(landed, 200)
      stale = json_response(refused, 409)

      assert ContractSchema.response_errors(stale, "POST", @write, 409) == []
      assert stale["error"]["code"] == "stale_revision"
      assert stale["error"]["details"] == %{"current_revision" => saved["revision"]}

      kept = read.(c.first)
      assert kept["revision"] == saved["revision"]

      assert kept["content"] in ["From the first agent.", "From the second agent."]

      # A stale write is sent once and never read back or sent again here.
      loser = if refused == first, do: c.first, else: c.second
      flush_hub()
      again = %{"path" => path, "content" => "Late.", "expected_revision" => revision}
      assert json_response(post!(c, loser, files <> "write", again), 409)
      loser_subject = loser.subject
      assert_received {:hub, "PUT", _put, ^loser_subject, _query, _body}
      refute_received {:hub, _method, _path, _subject, _query, _body}
      assert Agent.get(c.files, & &1[path]) == kept["content"]

      # Written over the revision it reads now, the change lands.
      merged = %{again | "content" => "Merged.", "expected_revision" => kept["revision"]}

      assert json_response(post!(c, loser, files <> "write", merged), 200)["revision"] ==
               Files.sha256("Merged.")

      assert Agent.get(c.files, & &1[path]) == "Merged."
    end
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
    over_read = Map.put(entry, "expected_revision", read["revision"])
    over = post!(c, c.second, files <> "write", %{over_read | "content" => "Second, over."})
    assert json_response(over, 403)["error"]["code"] == "notebooks_maker_only"
    own = post!(c, c.first, files <> "write", %{over_read | "content" => "First, corrected."})
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

    added = json_response(post!(c, c.first, files <> "add", entry), 200)
    assert added["path"] == "/log/a.md"

    answer_next(c, "PUT", "files", :paused)
    over = %{"content" => "First, corrected.", "expected_revision" => added["revision"]}
    paused = post!(c, c.first, files <> "write", Map.merge(entry, over))
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

    added = Files.write(@fleet, nil, c.first.subject, @space, @notebook, "log/a.md", "x", :add)

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

  # A file's text is counted in bytes, as the tool describes it, and text past
  # that is told how long it may be and how long it is.
  test "through /mcp a file's text is at most 20,480 bytes, and a longer one is told its length",
       c do
    oauth = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, oauth) end)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(oauth, :enabled?, true))

    where = %{"fleet_id" => @fleet, "project" => "general", "notebook_id" => @notebook}

    add =
      &mcp!(c, c.first, "notebooks_add_file", Map.merge(where, %{"path" => &1, "content" => &2}))

    # Two bytes a character: 10,240 of them fill the limit.
    longest = String.duplicate("é", 10_240)
    assert byte_size(longest) == 20_480
    added = Jason.decode!(add.("log/longest.md", longest).resp_body)["result"]
    assert %{"isError" => false, "structuredContent" => %{"path" => "/log/longest.md"}} = added

    for content <- [longest <> "é", String.duplicate("a", 45_568)] do
      refused = Jason.decode!(add.("log/over.md", content).resp_body)["result"]
      assert %{"isError" => true, "content" => [%{"text" => text}]} = refused
      error = Jason.decode!(text)["error"]
      assert error["code"] == "invalid_request"
      assert error["hint"] =~ "20480"
      assert error["hint"] =~ "#{byte_size(content)}"
    end
  end

  test "a notebook made for a goal carries the goal's tag, which lists it on the goal's page",
       c do
    made = %{"title" => "Boat count", "code" => "import marimo", "goal" => "goal#19"}

    assert json_response(
             post!(c, c.first, "#{@api}/create", Map.put(made, "idempotency_key", "nb-1")),
             200
           )

    first = c.first.subject
    assert_receive {:hub, "POST", @notebooks, ^first, _query, body}
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

      refute_receive {:hub, "POST", @notebooks, _subject, _query, _body}
    end
  end

  # Costly failure: one agent's job holds everyone's runs, so its maker
  # deleting it stops and loses the others' runs.
  test "each agent's runs go in a job of its own", c do
    runs = "#{@api}/#{@notebook}/runs/start"
    first = c.first.subject
    second = c.second.subject
    Agent.update(c.files, &Map.put(&1, "notebook.py", "import marimo"))

    # Each notebook as the Docs place lists it, with its description and when
    # it was added.
    list = json_response(post!(c, c.first, "#{@api}/list", %{}), 200)
    assert ContractSchema.errors(list, "NotebookList") == []
    assert [%{"description" => "", "created_at" => "2026-10-21T09:00:00Z"}] = list["notebooks"]

    started = post!(c, c.first, runs, %{"idempotency_key" => "run-1"})
    assert json_response(started, 200)["run_id"] == run_id(1)
    assert_receive {:hub, "POST", @jobs, ^first, _query, _body}

    again = post!(c, c.first, runs, %{"idempotency_key" => "run-2"})
    assert json_response(again, 200)["run_id"] == run_id(2)
    refute_receive {:hub, "POST", @jobs, _subject, _query, _body}

    post!(c, c.second, runs, %{"idempotency_key" => "run-3"})
    assert_receive {:hub, "POST", @jobs, ^second, _query, _body}

    jobs = Agent.get(c.files, & &1["jobs"])
    assert Enum.map(jobs, & &1["created_by"]) == [first, second]
    assert Enum.map(jobs, &length(&1["runs"])) == [2, 1]
  end

  # Costly failure: an agent builds on a notebook whose last run failed, or
  # whose result is older than its code, because the list showed only its own
  # runs; or the list asks the hub about every notebook, one by one.
  test "a listed notebook's state is its newest kept run page, whoever ran it", c do
    Agent.update(c.files, &Map.put(&1, "notebook.py", "import marimo"))

    state = fn agent ->
      list = json_response(post!(c, agent, "#{@api}/list", %{}), 200)
      assert ContractSchema.errors(list, "NotebookList") == []
      [%{"state" => state}] = list["notebooks"]
      state
    end

    # Nothing kept is no state, and nor is a page kept from a notebook version,
    # even one newer than every run's.
    assert state.(c.first) == nil
    version = "ver_" <> String.duplicate("0", 26)
    later = ms(~U[2026-11-15 13:00:00Z])
    Notebooks.keep_saved_output!(@fleet, @notebook, version, later, "v", false, actor: %System{})

    assert state.(c.first) == nil

    # The first agent's run worked; the second's, after it, failed, and the
    # second reads it.
    {mine, read_mine} = run!(c)
    finish!(c, mine, %{"status" => "succeeded", "finished_at" => "2026-11-15T12:00:00Z"})
    assert read_mine.()["result_url"]

    theirs =
      json_response(
        post!(c, c.second, "#{@api}/#{@notebook}/runs/start", %{"idempotency_key" => "theirs"}),
        200
      )["run_id"]

    finish!(c, theirs, %{
      "status" => "failed",
      "finished_at" => "2026-11-15T12:05:00Z",
      "failure" => %{
        "stage" => "export",
        "exit_status" => 1,
        "message" => "Cell 3 raised ValueError",
        "excerpt" => "ValueError: bad row 7"
      }
    })

    assert json_response(get!(c, c.second, "#{@api}/#{@notebook}/runs/#{theirs}"), 200)[
             "result_url"
           ]

    # The first agent's list says how the second's run went, from Keyfleet's
    # copies: it asks the hub for the page of notebooks and nothing else.
    flush_hub()
    listed = state.(c.first)
    assert_received {:hub, "GET", @notebooks, _subject, _query, _body}
    refute_received {:hub, "GET", @notebooks, _subject, _query, _body}
    refute_received {:hub, _method, @notebooks <> "/" <> _rest, _subject, _query, _body}

    saved_at = ms(~U[2026-11-15 12:05:00Z])

    assert listed == %{
             "run_id" => theirs,
             "worked" => false,
             "saved_at" => "2026-11-15T12:05:00.000Z",
             "error" => %{"stage" => "export", "message" => "Cell 3 raised ValueError"},
             "changed_since" => false,
             "result_url" => Notebooks.result_url(@fleet, @notebook, theirs, saved_at)
           }

    # Once the notebook changes after that page, the page is not of it as it is.
    changed = Map.put(log_notebook(), :updated_at, "2026-11-15T12:06:00Z")
    Agent.update(c.files, &Map.put(&1, "notebooks", [changed]))
    assert %{"run_id" => ^theirs, "changed_since" => true} = state.(c.second)
  end

  # Costly failure: an agent that ran a notebook can't tell whether its cells
  # rendered or raised, as the saved page sends an unsigned reader to the
  # workspace; or it is handed the page's HTML, far more than it can read.
  test "a notebook's page is what its newest kept run page holds, whoever ran it", c do
    oauth = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, oauth) end)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(oauth, :enabled?, true))

    printed = fixture_page("printed.html")
    pictures = fixture_page("pictures.html")
    page = &get!(c, &1, "#{@api}/#{@notebook}/page")
    keep = &Notebooks.keep_saved_output!(@fleet, @notebook, &1, ms(&2), &3, &4, actor: %System{})

    # Nothing kept, or only a page of a notebook version, even one newer than
    # every run's, is no run's page yet.
    for kept <- [nil, "ver_" <> String.duplicate("0", 26)] do
      if kept, do: keep.(kept, ~U[2026-11-15 13:00:00Z], printed, false)
      refused = json_response(page.(c.first), 404)
      assert refused["error"]["code"] == "notebook_page_not_kept"
      assert ContractSchema.errors(refused, "NotebookPageNotKeptError") == []
    end

    # The first agent's run made the older page; the second's, after it,
    # failed in a cell.
    keep.(run_id(1), ~U[2026-11-15 11:00:00Z], pictures, true)
    keep.(run_id(2), ~U[2026-11-15 12:00:00Z], printed, false)
    stopped = %{"stage" => "export", "message" => "Cell vblA raised ZeroDivisionError"}
    Notebooks.record_run_failure(@fleet, run_id(2), stopped)

    # The hub is asked for the notebook as the agent, and for nothing else.
    flush_hub()
    read = json_response(page.(c.first), 200)
    {first, notebook} = {c.first.subject, "#{@notebooks}/#{@notebook}"}
    assert_received {:hub, "GET", ^notebook, ^first, _query, _body}
    refute_received {:hub, _method, _path, _subject, _query, _body}
    assert ContractSchema.errors(read, "NotebookPage") == []

    assert Map.delete(read, "cells") == %{
             "notebook_id" => @notebook,
             "run_id" => run_id(2),
             "worked" => false,
             "saved_at" => "2026-11-15T12:00:00.000Z",
             "error" => stopped,
             "result_url" =>
               Notebooks.result_url(@fleet, @notebook, run_id(2), ms(~U[2026-11-15 12:00:00Z])),
             "size" => byte_size(printed),
             "sha256" => Files.sha256(printed),
             "truncated" => false
           }

    assert [loaded, shown, raised, _after_it] = read["cells"]

    assert [
             %{"name" => "stdout", "text" => "loading rows\n"},
             %{"name" => "stderr", "text" => "two rows skipped\n"}
           ] = loaded["console"]

    assert [%{"mimetype" => "text/markdown", "text" => markdown}] = shown["outputs"]
    assert markdown =~ "<strong>Rows:</strong> 3"
    assert %{"kind" => "exception", "message" => "division by zero"} = raised["error"]

    # A newer run's page: its picture is named with its size and no text, and
    # its long output is cut, which the answer says.
    keep.(run_id(3), ~U[2026-11-15 12:30:00Z], pictures, true)
    read = json_response(page.(c.second), 200)
    assert ContractSchema.errors(read, "NotebookPage") == []
    assert %{"run_id" => run_3, "worked" => true, "truncated" => true} = read
    assert run_3 == run_id(3)
    assert byte_size(Jason.encode!(read)) <= 256 * 1024

    assert [dot, _figure, _bundle, long] = read["cells"]
    assert [%{"mimetype" => "image/png", "text" => nil, "bytes" => bytes}] = dot["outputs"]
    assert bytes > 0
    assert [%{"mimetype" => "text/html", "cut" => true, "text" => text}] = long["outputs"]
    assert byte_size(text) == 16 * 1024

    # The Claude connector answers the same.
    where = %{"fleet_id" => @fleet, "project" => "general", "notebook_id" => @notebook}
    called = Jason.decode!(mcp!(c, c.second, "notebooks_page", where).resp_body)["result"]
    assert %{"isError" => false, "structuredContent" => ^read} = called
  end

  # Costly failure: a kept page whose cells can't be read is answered as a
  # notebook that printed and showed nothing.
  test "a notebook's newest kept page with no session it can read is refused", c do
    keep_run!(run_id(1), ~U[2026-11-15 11:00:00Z], fixture_page("printed.html"))
    keep_run!(run_id(2), ~U[2026-11-15 12:00:00Z], "<p>#{run_id(2)}</p>")

    refused = json_response(get!(c, c.first, "#{@api}/#{@notebook}/page"), 422)
    assert refused["error"]["code"] == "notebook_page_unreadable"
    assert ContractSchema.errors(refused, "NotebookPageUnreadableError") == []
  end

  # Costly failure: a kept page, which names no project, is read through a
  # project the notebook isn't in, or by an agent kept out of the notebooks.
  test "a notebook's page is read only through its own project, by its notebooks' members", c do
    elsewhere = "nb-00000000000000ff"
    other_run = "run_" <> String.duplicate("1", 26)

    Notebooks.keep_saved_output!(
      @fleet,
      elsewhere,
      other_run,
      ms(~U[2026-11-15 11:00:00Z]),
      "p",
      true,
      actor: %System{}
    )

    refused = json_response(get!(c, c.first, "#{@api}/#{elsewhere}/page"), 404)
    assert refused["error"]["code"] == "notebook_run_not_found"

    keep_run!(run_id(1), ~U[2026-11-15 11:00:00Z], fixture_page("printed.html"))
    outsider = paired!("Outsider")
    flush_hub()

    refused = json_response(get!(c, outsider, "#{@api}/#{@notebook}/page"), 403)
    assert refused["error"]["code"] == "notebooks_not_holder"
    refute_received {:hub, _method, "/api/v1/projects/" <> _rest, _subject, _query, _body}
  end

  # Costly failure: a project with more notebooks than one answer holds keeps
  # its older ones from every agent, which can neither find nor run them.
  test "a project's notebooks list a page at a time, newest first, to the last", c do
    notebooks =
      for n <- 1..101 do
        added = DateTime.add(~U[2026-11-15 09:00:00Z], -n, :minute)
        id = "nb-" <> String.pad_leading(Integer.to_string(n), 16, "0")
        at = DateTime.to_iso8601(added)
        %{id: id, title: "Note #{n}", description: "", created_at: at, updated_at: at}
      end

    Agent.update(c.files, &Map.put(&1, "notebooks", notebooks))
    list = &json_response(post!(c, c.first, "#{@api}/list", &1), 200)

    first = list.(%{})
    assert %{"has_more" => true, "cursor" => cursor} = first
    assert is_binary(cursor)

    second = list.(%{"cursor" => cursor})
    assert %{"has_more" => true, "cursor" => cursor} = second

    last = list.(%{"cursor" => cursor})
    assert %{"has_more" => false, "cursor" => nil} = last

    pages = [first, second, last]
    for page <- pages, do: assert(ContractSchema.errors(page, "NotebookList") == [])
    assert Enum.map(pages, &length(&1["notebooks"])) == [50, 50, 1]

    assert Enum.flat_map(pages, fn page -> Enum.map(page["notebooks"], & &1["notebook_id"]) end) ==
             Enum.map(notebooks, & &1.id)

    # A cursor no page answered is refused alike here and in a notebook's files.
    refused = post!(c, c.first, "#{@api}/list", %{"cursor" => "after:nb-ffffffffffffffff"})
    assert %{"error" => error} = json_response(refused, 422)
    assert error["code"] == "notebook_cursor_unknown"
    assert ContractSchema.errors(%{"error" => error}, "NotebookCursorError") == []

    answer_next(c, "GET", "entries", :refuses)
    files = post!(c, c.first, "#{@api}/#{@notebook}/files/list", %{"cursor" => "made-up"})
    assert json_response(files, 422) == %{"error" => error}
  end

  # Costly failure: an agent handed a task's notebook address takes its proj-…
  # part, the notebook host's own id, for the project, and every read of the
  # notebook is refused. links_resolve names the project and notebook they take.
  test "a task's notebook address reads as the project and notebook a file read takes", c do
    Agent.update(c.files, &Map.put(&1, "notebook.py", "import marimo"))

    [%{"notebook_url" => url}] =
      json_response(post!(c, c.first, "#{@api}/list", %{}), 200)["notebooks"]

    Workspace.open_log(@fleet)
    task = Workspace.create(@fleet, "task", %{"title" => "Count boats", "notebook_ref" => url})
    shown = post!(c, c.first, "/api/v1/agent/fleets/#{@fleet}/graph/get", %{"id" => task})
    cited = json_response(shown, 200)["object"]["data"]["notebook_ref"]
    assert cited == url

    link = json_response(post!(c, c.first, "/api/v1/agent/links/resolve", %{"url" => cited}), 200)
    assert ContractSchema.errors(link, "Link") == []

    assert %{"kind" => "notebook", "read" => %{"tool" => "notebooks_files", "input" => input}} =
             link

    %{"project" => project, "notebook_id" => notebook} = input
    assert {project, notebook} == {"general", @notebook}

    files = "/api/v1/agent/fleets/#{@fleet}/projects/#{project}/notebooks/#{notebook}/files/"
    read = json_response(post!(c, c.first, files <> "read", %{"path" => "notebook.py"}), 200)
    assert read["content"] == "import marimo"
  end

  # Costly failure: an agent handed the Atlas's or the workspace's link to a
  # notebook, which opens it through this site, is told the address names
  # nothing and picks the ids out by hand.
  test "a link that opens a notebook here reads as that notebook, or as its saved page", c do
    site = String.replace_prefix(KeyfleetWeb.Endpoint.url(), "http://", "https://")
    open = &"#{site}/fleets/#{&1}/notebooks/open?#{URI.encode_query(to: &2)}"
    resolve = &post!(c, c.first, "/api/v1/agent/links/resolve", %{"url" => &1})

    link = json_response(resolve.(open.(@fleet, Notebooks.notebook_path(@space, @notebook))), 200)
    assert ContractSchema.errors(link, "Link") == []

    assert %{"kind" => "notebook", "read" => %{"tool" => "notebooks_files", "input" => input}} =
             link

    assert input == %{"fleet_id" => @fleet, "project" => "general", "notebook_id" => @notebook}

    run_id = "run_" <> String.duplicate("0", 26)
    saved = Notebooks.result_path(@notebook, run_id, 1_763_000_000_000)

    assert %{"kind" => "notebook_result", "names" => names} =
             json_response(resolve.(open.(@fleet, saved)), 200)

    assert %{"notebook_id" => @notebook, "run_id" => ^run_id} = names

    for unknown <- [open.(@fleet, "/"), open.("fleet_tech_classic", saved)] do
      assert json_response(resolve.(unknown), 422)["error"]["code"] == "link_unknown"
    end
  end

  # Costly failure: an agent puts the proj-… id from a notebook's address where
  # the project's name goes and is refused on some notebook route without
  # being told the id isn't a project's name or how to read the address.
  test "every notebook route given a notebook address's proj- id refuses it as no project", c do
    by_id = "/api/v1/agent/fleets/#{@fleet}/projects/#{@space}/notebooks"
    notebook = "#{by_id}/#{@notebook}"
    file = %{"path" => "notebook.py", "content" => "import marimo"}

    calls = [
      {:post, "#{by_id}/list", %{}},
      {:post, "#{by_id}/create",
       %{"title" => "Log", "code" => "import marimo", "idempotency_key" => "nb-1"}},
      {:post, "#{notebook}/files/list", %{}},
      {:post, "#{notebook}/files/read", %{"path" => "notebook.py"}},
      {:post, "#{notebook}/files/add", file},
      {:post, "#{notebook}/files/write", Map.put(file, "expected_revision", "r1")},
      {:post, "#{notebook}/lock", %{"locked" => false}},
      {:get, "#{by_id}/copies"},
      {:post, "#{by_id}/copies/#{Ecto.UUID.generate()}/restore", %{}},
      {:post, "#{notebook}/runs/start", %{"idempotency_key" => "run-1"}},
      {:get, "#{notebook}/runs/#{run_id(1)}"}
    ]

    hint = KeyfleetWeb.Refusal.body("project_unknown").error.hint

    for call <- calls do
      answer =
        case call do
          {:get, path} -> get!(c, c.first, path)
          {:post, path, body} -> post!(c, c.first, path, body)
        end

      assert %{"code" => "project_unknown", "hint" => ^hint, "details" => details} =
               json_response(answer, 404)["error"]

      assert details["project"] == @space
    end

    refute_received {:hub, _method, @notebooks <> _rest, _subject, _query, _body}
  end

  describe "a finished run's files" do
    setup c do
      Agent.update(c.files, fn kept ->
        Map.merge(kept, %{
          "notebook.py" => "import marimo\nfrom helper import total",
          "helper.py" => "def total(): return 1",
          "data/rows.csv" => "a,b\n1,2",
          "__marimo__/session/notebook.py.json" => ~s({"cells": []})
        })
      end)

      :ok
    end

    # Costly failure: an agent cites a result as the notebook's current
    # output because the entry file is unchanged, while a helper beside it
    # that the result depends on has changed since.
    test "a helper changed after the run leaves the entry current and the whole bundle not",
         c do
      {run_id, read} = run!(c)

      assert %{"entry_current" => nil, "bundle_current" => nil} = read.()

      finish!(c, run_id)
      answer = read.()
      assert %{"entry_current" => true, "bundle_current" => true} = answer

      source = answer["source"]
      assert ContractSchema.errors(source, "NotebookRunSource") == []
      assert source["files_complete"]

      assert Enum.map(source["files"], &{&1["path"], &1["revision"]}) ==
               for(
                 path <- ["data/rows.csv", "helper.py", "notebook.py"],
                 do: {"/" <> path, Files.sha256(Agent.get(c.files, & &1[path]))}
               )

      Agent.update(c.files, &Map.put(&1, "helper.py", "def total(): return 2"))
      assert %{"entry_current" => true, "bundle_current" => false} = read.()
    end

    # Costly failure: every result reads as stale once anyone opens the
    # notebook, because marimo rewrites its own session caches.
    test "marimo's own files changing leaves both current; the entry changing leaves neither",
         c do
      {run_id, read} = run!(c)
      finish!(c, run_id)

      Agent.update(c.files, fn kept ->
        kept
        |> Map.put("__marimo__/session/notebook.py.json", ~s({"cells": [1]}))
        |> Map.put("lib/__marimo__/notebook.html", "<p>page</p>")
      end)

      assert %{"entry_current" => true, "bundle_current" => true} = read.()

      Agent.update(c.files, &Map.put(&1, "notebook.py", "import marimo\nprint(2)"))
      assert %{"entry_current" => false, "bundle_current" => false} = read.()
    end

    test "a file added or removed after the run leaves the bundle not current", c do
      {added, read_added} = run!(c)
      finish!(c, added)
      Agent.update(c.files, &Map.put(&1, "data/more.csv", "c\n3"))
      assert %{"entry_current" => true, "bundle_current" => false} = read_added.()

      {removed, read_removed} = run!(c)
      finish!(c, removed)
      Agent.update(c.files, &Map.delete(&1, "data/rows.csv"))
      assert %{"entry_current" => true, "bundle_current" => false} = read_removed.()
    end

    # Completeness says whether the record holds every file; freshness whether
    # those files are still the notebook's. Each is told apart from the other.
    test "an incomplete record or a missing revision leaves the bundle unknown, not current",
         c do
      Agent.update(c.files, fn kept ->
        Map.merge(kept, Map.new(1..500, &{"zz/#{&1}.txt", "#{&1}"}))
      end)

      {partial, read_partial} = run!(c)
      finish!(c, partial)
      answer = read_partial.()
      refute answer["source"]["files_complete"]
      assert length(answer["source"]["files"]) < 500
      assert %{"entry_current" => true, "bundle_current" => nil} = answer

      # A file the record does hold, changed: seen, so not current.
      Agent.update(c.files, &Map.put(&1, "helper.py", "def total(): return 2"))
      assert %{"bundle_current" => false} = read_partial.()

      Agent.update(c.files, fn kept ->
        kept |> Map.reject(fn {path, _} -> is_binary(path) and path =~ ~r/^zz\// end)
      end)

      Agent.update(c.files, &Map.put(&1, "unrevised", ["helper.py"]))
      {unrevised, read_unrevised} = run!(c)
      finish!(c, unrevised)
      answer = read_unrevised.()
      assert answer["source"]["files_complete"]
      helper = Enum.find(answer["source"]["files"], &(&1["path"] == "/helper.py"))
      assert helper["revision"] == nil
      assert %{"entry_current" => true, "bundle_current" => nil} = answer
    end

    # A hub that names no revision: the record holds every file, so it is
    # complete, yet says nothing of whether they are still the same.
    test "a record of every file with no revisions is complete, and its bundle unknown", c do
      Agent.update(
        c.files,
        &Map.put(&1, "unrevised", ["notebook.py", "helper.py", "data/rows.csv"])
      )

      {run_id, read} = run!(c)
      finish!(c, run_id)
      Agent.update(c.files, &Map.delete(&1, "unrevised"))

      answer = read.()
      assert answer["source"]["files_complete"]
      assert Enum.map(answer["source"]["files"], & &1["revision"]) == [nil, nil, nil]
      assert %{"entry_current" => true, "bundle_current" => nil} = answer

      # Nor is a file it lists, gone from the notebook now, evidence of a change.
      Agent.update(c.files, &Map.delete(&1, "data/rows.csv"))
      assert %{"entry_current" => true, "bundle_current" => nil} = read.()
    end
  end

  # Starts a run as the first agent, answering its id and a read of it.
  defp run!(c) do
    key = "run-#{:erlang.unique_integer([:positive])}"

    run_id =
      json_response(
        post!(c, c.first, "#{@api}/#{@notebook}/runs/start", %{"idempotency_key" => key}),
        200
      )["run_id"]

    {run_id,
     fn -> json_response(get!(c, c.first, "#{@api}/#{@notebook}/runs/#{run_id}"), 200) end}
  end

  # Run `run_id` ends as `ending` says; one with `finished_at` has its page.
  defp finish!(c, run_id, ending \\ %{"status" => "succeeded"}) do
    Agent.update(c.files, fn kept ->
      %{
        kept
        | "jobs" =>
            Enum.map(
              kept["jobs"],
              &%{&1 | "runs" => Enum.map(&1["runs"], fn run -> finished(run, run_id, ending) end)}
            )
      }
    end)
  end

  defp finished(%{"run_id" => run_id} = run, run_id, ending), do: Map.merge(run, ending)
  defp finished(run, _run_id, _ending), do: run

  defp run_id(n), do: "run_" <> String.pad_leading(Integer.to_string(n), 26, "0")

  defp ms(at), do: DateTime.to_unix(at, :millisecond)

  # A page marimo exported, kept for tests (`Keyfleet.Notebooks.PageTest`).
  defp fixture_page(name),
    do: File.read!(Path.expand("../support/fixtures/notebook_pages/#{name}", __DIR__))

  defp keep_run!(run_id, at, page),
    do:
      Notebooks.keep_saved_output!(@fleet, @notebook, run_id, ms(at), page, true,
        actor: %System{}
      )

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

  defp flush_hub do
    receive do
      {:hub, _method, _path, _subject, _query, _body} -> flush_hub()
    after
      0 -> :ok
    end
  end

  # Each request has its own id, so two refusals are compared without it.
  defp without_request_id(error),
    do: update_in(error, ["details", "receipt"], &Map.delete(&1, "request_id"))

  # What the agent did last in the fleet, as its check-in records it.
  defp last_did(agent) do
    check_in = Keyfleet.Agents.get_check_in!(agent.profile_id, @fleet)
    check_in && check_in.last_contribution_kind
  end

  # An agent with a profile, paired with the person who owns Key `token_id`.
  defp agent!(token_id) do
    agent = paired!("Mate #{token_id}")
    epoch!(token_id, agent.wallet)
    agent
  end

  # An agent with a profile, paired with a person who holds none of the
  # fleet's Keys.
  defp paired!(name) do
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: name, declared_harness: "local"},
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
        run = %{"run_id" => run_id(length(all) + 1), "status" => "queued"}

        {run, %{kept | "jobs" => Enum.map(kept["jobs"], &with_run(&1, job_id, run))}}
      end)

    json(conn, 201, %{success: true, data: run})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @jobs <> "/" <> runs} = conn,
         files,
         _body
       ) do
    case String.split(runs, "/") do
      [job_id, "runs"] ->
        job = Enum.find(Agent.get(files, & &1["jobs"]), &(&1["id"] == job_id))
        json(conn, 200, %{success: true, data: %{items: Enum.take(job["runs"], 1)}})

      [_job_id, "runs", run_id] ->
        run_answer(conn, Enum.find(all_runs(files), &(&1["run_id"] == run_id)))

      [_job_id, "runs", run_id, "html"] ->
        run_page(conn, Enum.find(all_runs(files), &(&1["run_id"] == run_id)))
    end
  end

  # The notebooks other than the one these tests work in have no jobs.
  defp hub_answer(
         %Plug.Conn{
           method: "GET",
           path_info: ["api", "v1", "projects", @space, "notebooks", _, "jobs"]
         } =
           conn,
         _files,
         _body
       ),
       do: json(conn, 200, %{success: true, data: %{items: []}})

  # One of the project's notebooks, as the hub answers it to a member; a
  # notebook of another project's space isn't one of them.
  defp hub_answer(
         %Plug.Conn{method: "GET", path_info: ["api", "v1", "projects", @space, "notebooks", id]} =
           conn,
         files,
         _body
       ) do
    case Enum.find(Agent.get(files, &Map.get(&1, "notebooks", [log_notebook()])), &(&1.id == id)) do
      nil ->
        json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No notebook"}})

      notebook ->
        json(conn, 200, %{success: true, data: notebook})
    end
  end

  # The project's notebooks, newest first, kept under "notebooks" (one, unless
  # a test sets them), a page of at most `limit` at a time as the hub pages
  # them: `next_cursor` names the rest, or is null after the last, and a
  # cursor it never answered is refused.
  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @notebooks} = conn,
         files,
         _body
       ) do
    notebooks = Agent.get(files, &Map.get(&1, "notebooks", [log_notebook()]))
    limit = String.to_integer(conn.query_params["limit"])

    case after_cursor(notebooks, conn.query_params["cursor"]) do
      {:ok, rest} ->
        {page, more} = Enum.split(rest, limit)
        next = if more != [], do: "after:" <> List.last(page).id
        json(conn, 200, %{success: true, data: %{items: page, next_cursor: next}})

      :error ->
        json(conn, 400, %{success: false, error: %{code: "BAD_REQUEST", message: "Bad cursor"}})
    end
  end

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: @notebooks} = conn,
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
    # One folder's files and folders, or with `recursive` every file under it
    # at any depth, as a run's record of its files reads them; the jobs kept
    # beside the files are not files. A page holds at most `limit`, and a
    # cursor names the rest. A file under "unrevised" is listed with no ETag.
    folder = if path = conn.query_params["path"], do: path <> "/", else: ""
    recursive = conn.query_params["recursive"] == "true"
    limit = String.to_integer(conn.query_params["limit"] || "200")
    kept = Agent.get(files, & &1)

    listed =
      &Map.drop(item(&1, &2), if(&1 in Map.get(kept, "unrevised", []), do: [:etag], else: []))

    entries =
      for {path, content} when is_binary(content) <- Enum.sort(kept),
          String.starts_with?(path, folder),
          uniq: true do
        case String.split(String.replace_prefix(path, folder, ""), "/", parts: 2) do
          [_name] -> listed.(path, content)
          [_folder, _rest] when recursive -> listed.(path, content)
          [inner, _rest] -> %{path: "/" <> folder <> inner, name: inner, kind: "directory"}
        end
      end

    page = %{items: Enum.take(entries, limit)}
    page = if length(entries) > limit, do: Map.put(page, :cursor, "next"), else: page
    json(conn, 200, %{success: true, data: page})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @workspace <> "files"} = conn,
         files,
         _body
       ) do
    case Agent.get(files, &Map.fetch(&1, conn.query_params["path"])) do
      {:ok, content} ->
        conn |> etag(content) |> send_resp(200, content)

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
    if_match = conn |> get_req_header("if-match") |> List.first()

    written =
      Agent.get_and_update(files, fn kept ->
        case stored(kept, path, create == "true", if_match) do
          :ok -> {:ok, Map.put(kept, path, body)}
          refused -> {refused, kept}
        end
      end)

    case written do
      :ok ->
        conn |> etag(body) |> json(200, %{success: true, data: item(path, body)})

      :conflict ->
        json(conn, 409, %{success: false, error: %{code: "CONFLICT", message: "already exists"}})

      :not_found ->
        json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No such file"}})

      {:changed, current} ->
        conn
        |> etag(current)
        |> json(412, %{
          success: false,
          error: %{code: "PRECONDITION_FAILED", message: "changed since it was read"}
        })
    end
  end

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/#{@space}/members"} = conn,
         _files,
         _body
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  # A run records the code it ran from, so starting one reads the notebook's
  # entry file.
  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "#{@notebooks}/#{@notebook}/content"} = conn,
         files,
         _body
       ),
       do: json(conn, 200, %{success: true, data: %{code: Agent.get(files, & &1["notebook.py"])}})

  defp hub_answer(conn, _files, _body), do: json(conn, 200, %{success: true, data: %{}})

  # Whether a write lands on the files `kept`, as the hub's store decides it.
  defp stored(kept, path, create, if_match) do
    cond do
      in_the_way?(kept, path) or (create and Map.has_key?(kept, path)) -> :conflict
      if_match == nil -> :ok
      not Map.has_key?(kept, path) -> :not_found
      if_match != quoted(kept[path]) -> {:changed, kept[path]}
      true -> :ok
    end
  end

  # A folder at the path, or a file where one of its folders would be.
  defp in_the_way?(kept, path) do
    Enum.any?(kept, fn {kept_path, content} ->
      is_binary(content) and
        (String.starts_with?(kept_path, path <> "/") or
           String.starts_with?(path, kept_path <> "/"))
    end)
  end

  # The hub keeps the file, then answers after Keyfleet has stopped waiting.
  defp hub_next(:keeps_then_hangs, conn, files, body) do
    path = conn.query_params["path"]
    Agent.update(files, &Map.put(&1, path, body))
    Process.sleep(600)
    conn |> etag(body) |> json(200, %{success: true, data: item(path, body)})
  end

  # The hub fails before changing anything.
  defp hub_next(:fails, conn, _files, _body),
    do: json(conn, 502, %{success: false, error: %{code: "BAD_GATEWAY", message: "Upstream"}})

  # The hub refuses the request as it asks.
  defp hub_next(:refuses, conn, _files, _body),
    do: json(conn, 400, %{success: false, error: %{code: "BAD_REQUEST", message: "Bad cursor"}})

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

  # The notebooks after the one a cursor names; no cursor, all of them.
  defp after_cursor(notebooks, nil), do: {:ok, notebooks}

  defp after_cursor(notebooks, "after:" <> id) do
    case Enum.split_while(notebooks, &(&1.id != id)) do
      {_before, [_named | rest]} -> {:ok, rest}
      {_all, []} -> :error
    end
  end

  defp after_cursor(_notebooks, _cursor), do: :error

  defp with_run(%{"id" => job_id} = job, job_id, run), do: %{job | "runs" => [run | job["runs"]]}
  defp with_run(job, _job_id, _run), do: job

  defp all_runs(files),
    do: Agent.get(files, &Enum.flat_map(&1["jobs"], fn job -> job["runs"] end))

  defp run_answer(conn, nil),
    do: json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No run"}})

  defp run_answer(conn, run), do: json(conn, 200, %{success: true, data: run})

  # A run's page, made when it finished, as the hub names it; a run that
  # hasn't finished with one has none.
  defp run_page(conn, %{"finished_at" => finished_at} = run) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-marimohub-run-id", run["run_id"])
    |> put_resp_header("x-marimohub-run-status", run["status"])
    |> put_resp_header("x-marimohub-captured-at", finished_at)
    |> send_resp(200, "<p>#{run["run_id"]}</p>")
  end

  defp run_page(conn, _run),
    do: json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No page"}})

  # The one notebook these tests work in, as the hub lists it: `updated_at`
  # is when its code, packages or details last changed.
  defp log_notebook,
    do: %{
      id: @notebook,
      title: "Log",
      description: "",
      created_at: "2026-10-21T09:00:00Z",
      updated_at: "2026-10-21T09:00:00Z"
    }

  defp item(path, content),
    do: %{
      path: "/" <> path,
      name: Path.basename(path),
      kind: "file",
      size: byte_size(content),
      modified_at: 1,
      etag: quoted(content)
    }

  defp etag(conn, content), do: put_resp_header(conn, "etag", quoted(content))
  defp quoted(content), do: ~s("#{Files.sha256(content)}")

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
