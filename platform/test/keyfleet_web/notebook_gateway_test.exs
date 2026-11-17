defmodule KeyfleetWeb.NotebookGatewayTest do
  # The fleets' notebook hubs are reached only through this site. Each test
  # names the costly failure it guards against; the hub is a local server that
  # records every request it gets.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{ChainHelpers, Fleets, Keys, Notebooks, Projects}
  alias Keyfleet.Notebooks.Roster
  alias KeyfleetWeb.{NotebookSocket, SessionAuthorityHelpers, SignedAgentHelpers}

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @host "fibonacci-syndicate.notebooks.localhost"
  @other_host "fibonacci-cascade.notebooks.localhost"
  @holder_wallet "0x" <> String.duplicate("a", 40)
  @buyer_wallet "0x" <> String.duplicate("b", 40)

  setup context do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    epoch!(1, 1, @holder_wallet)

    holder = account!("did:privy:notebook-holder", @holder_wallet)
    buyer = account!("did:privy:notebook-buyer", @buyer_wallet)

    test = self()

    hub =
      server(fn conn ->
        {:ok, body, conn} = read_body(conn)
        [pass] = get_req_header(conn, "x-keyfleet-assertion")
        send(test, {:hub, conn.method, conn.request_path, subject(pass), body})

        if delay = context[:hub_delay_ms][{conn.method, conn.request_path}] do
          Process.sleep(delay)
        end

        hub_answer(conn, holder)
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(notebooks, :fleets, %{@fleet => hub, @other_fleet => hub})
    )

    for {fleet_id, space} <- [{@fleet, "proj-fleet"}, {@other_fleet, "proj-other"}] do
      fleet_id
      |> Projects.project!(Projects.general(), actor: %System{})
      |> Projects.record_space!(space, actor: %System{})
    end

    # Key 1 takes over the fleet's archived `general`, so its notebooks take changes.
    Projects.take_over_project!(@fleet, 1, Projects.general(), actor: holder)

    %{holder: holder, buyer: buyer}
  end

  # Costly failure: someone without a key reads or writes a fleet's notebooks.
  test "a person who holds none of the fleet's keys never reaches its hub", c do
    assert Notebooks.open(c.buyer, signed_in!(c.buyer), @fleet) == {:error, :not_holder}

    cookie = enter!(c.holder)
    assert get_notebook(@host, "/", cookie).status == 200
    assert_receive {:hub, "GET", "/", "u_" <> _, _body}

    # The key changes hands while the holder's notebooks are open.
    epoch!(1, 2, @buyer_wallet)
    Notebooks.end_access(@fleet, Notebooks.subject(c.holder))

    refused = get_notebook(@host, "/api/v1/projects", cookie)
    assert refused.status == 403
    assert json_response(refused, 403)["error"]["code"] == "notebooks_not_holder"
    refute_received {:hub, _method, "/api/v1/projects", "u_" <> _, _body}
  end

  # Costly failure: a notebook connection opened just before the notebook
  # sign-in ends stays open long after it, until the Keyfleet sign-in ends.
  test "what a person opens ends when their notebook sign-in does", c do
    entered = DateTime.to_unix(DateTime.utc_now())
    cookie = enter!(c.holder)
    pass_ends = entered + Notebooks.config()[:session_max_age]

    opened = get_notebook(@host, "/", cookie)
    assert opened.status == 200
    ends_at = DateTime.to_unix(opened.assigns.notebook_sign_in.ends_at)
    assert ends_at in pass_ends..(pass_ends + 1)
  end

  # Costly failure: someone who signed out of Keyfleet, on a shared computer,
  # leaves the fleet's notebooks open to the next person at that browser, in a
  # new request or a notebook connection already open.
  test "signing out of Keyfleet signs the notebooks out too", c do
    session = SessionAuthorityHelpers.signed_in_session(c.holder.human_account_id)
    lineage = session["session_lineage"]
    cookie = enter!(c.holder, lineage)
    assert get_notebook(@host, "/", cookie).status == 200

    # What an open notebook connection opened with this cookie listens on.
    {:ok, %{"session_authority_id" => sign_in}} =
      Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, "notebook session", cookie)

    {:ok, _person, topic, _ends_at} = Notebooks.person(sign_in, c.holder.human_account_id)

    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

    signed_out =
      build_conn()
      |> SessionAuthorityHelpers.init_test_session(session)
      |> delete("/auth/privy/session")

    assert json_response(signed_out, 200) == %{"ok" => true}
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

    refused = get_notebook(@host, "/api/v1/me", cookie)
    assert json_response(refused, 401)["error"]["code"] == "notebooks_sign_in"
    assert Notebooks.open(c.holder, lineage, @fleet) == {:error, :signed_out}

    # A link to the notebooks goes to Keyfleet to sign in again.
    for page <- ["/", "/projects/proj-0000000000000001/notebooks/nb-0000000000000001"] do
      again = get_notebook(@host, page, cookie)
      assert again.status == 303

      assert get_resp_header(again, "location") == [
               KeyfleetWeb.Plugs.NotebookGateway.open_url(@fleet, page)
             ]
    end
  end

  # Costly failure: a sign-out or a Key changing hands between the gateway's
  # checks and the connection listening for either is missed, so that
  # connection stays open until the sign-in runs out.
  test "a notebook connection reads the sign-in and the Key again once it listens", c do
    session = SessionAuthorityHelpers.signed_in_session(c.holder.human_account_id)
    cookie = enter!(c.holder, session["session_lineage"])

    {:ok, %{"session_authority_id" => sign_in}} =
      Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, "notebook session", cookie)

    {:ok, _person, topic, ends_at} = Notebooks.person(sign_in, c.holder.human_account_id)

    opening = %{
      fleet_id: @fleet,
      subject: Notebooks.subject(c.holder),
      holder: {:person, sign_in, c.holder.human_account_id},
      sign_in_topic: topic,
      sign_in_ends_at: ends_at
    }

    epoch!(1, 2, @buyer_wallet)

    assert {:stop, :normal, {1008, "Your Key no longer opens these notebooks."}, _state} =
             NotebookSocket.init(opening)

    build_conn()
    |> SessionAuthorityHelpers.init_test_session(session)
    |> delete("/auth/privy/session")

    assert {:stop, :normal, {1008, "You signed out of Keyfleet."}, _state} =
             NotebookSocket.init(opening)
  end

  # Costly failure: a Key a fleet vote restricted from editing goes on
  # changing the fleet's notebooks, by a request or a live connection.
  test "a Key a vote restricted reads the notebooks and changes nothing until a vote allows it",
       c do
    session = SessionAuthorityHelpers.signed_in_session(c.holder.human_account_id)
    cookie = enter!(c.holder, session["session_lineage"])
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    assert post_notebook(@host, notebooks, cookie).status == 201
    assert_receive {:hub, "POST", ^notebooks, "u_" <> _, _body}

    # The vote passes; the chain reader then checks everyone afresh.
    restrict!(1, true, 1)
    Notebooks.end_access(@fleet)

    assert get_notebook(@host, notebooks, cookie).status == 200
    assert_receive {:hub, "GET", ^notebooks, "u_" <> _, _body}

    refused = post_notebook(@host, notebooks, cookie)
    assert json_response(refused, 403)["error"]["code"] == "notebooks_edits_restricted"
    refute_received {:hub, "POST", ^notebooks, _, _body}

    {:ok, %{"session_authority_id" => sign_in}} =
      Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, "notebook session", cookie)

    {:ok, _person, topic, ends_at} = Notebooks.person(sign_in, c.holder.human_account_id)

    opening = %{
      fleet_id: @fleet,
      subject: Notebooks.subject(c.holder),
      holder: {:person, sign_in, c.holder.human_account_id},
      sign_in_topic: topic,
      sign_in_ends_at: ends_at
    }

    assert {:stop, :normal, {1008, "A vote of the fleet has stopped your Key" <> _}, _state} =
             NotebookSocket.init(opening)

    restrict!(1, false, 2)
    Notebooks.end_access(@fleet)

    assert post_notebook(@host, notebooks, cookie).status == 201
    assert_receive {:hub, "POST", ^notebooks, "u_" <> _, _body}
  end

  # Costly failure: work is added to an archived project's notebooks, which
  # take nothing until a Key takes the project over.
  test "nobody changes an archived project's notebooks, and they can still be read", c do
    cookie = enter!(c.holder)
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    Projects.archive_project!(@fleet, 1, actor: c.holder)

    assert get_notebook(@host, notebooks, cookie).status == 200
    assert_receive {:hub, "GET", ^notebooks, "u_" <> _, _body}

    for {method, path} <- [
          {:post, notebooks},
          {:post, notebooks <> "/nb-0000000000000002/sessions"},
          {:post, notebooks <> "/nb-0000000000000002/sessions/sess-mine/heartbeat"},
          {:put, notebooks <> "/nb-0000000000000002/workspace/files?path=/mine.csv"}
        ] do
      refused = send_notebook(method, path, cookie, "{}")
      assert json_response(refused, 403)["error"]["code"] == "notebooks_project_archived"
    end

    refute_received {:hub, "POST", "/api/v1/projects/proj-fleet/notebooks" <> _, _subject, _body}
    refute_received {:hub, "PUT", "/api/v1/projects/proj-fleet/notebooks" <> _, _subject, _body}

    Projects.take_over_project!(@fleet, 1, Projects.general(), actor: c.holder)
    assert post_notebook(@host, notebooks, cookie).status == 201
    assert_receive {:hub, "POST", ^notebooks, "u_" <> _, _body}
  end

  # Costly failure: a page a member's notebook wrote runs on the fleet's
  # notebook host as whoever opened it, and removes their files.
  test "a notebook's own pages run in a sandbox", c do
    cookie = enter!(c.holder)
    notebook = "/api/v1/projects/proj-fleet/notebooks/nb-0000000000000001"

    for page <- ["/html", "/versions/ver_1/html", "/jobs/job-1/runs/run_1/html"] do
      answer = send_notebook(:get, notebook <> page, cookie, "")
      assert answer.status == 200
      assert "sandbox allow-scripts" in get_resp_header(answer, "content-security-policy")
    end

    refute "sandbox allow-scripts" in get_resp_header(
             send_notebook(:get, notebook, cookie, ""),
             "content-security-policy"
           )
  end

  # Costly failure: a failed run's page opened here is kept without how the
  # run failed, so every agent's notebook list shows it failed for no reason;
  # or its output, which only its starter and author may read, is kept for all.
  test "a failed run's page kept here records where the run stopped, and keeps it", c do
    cookie = enter!(c.holder)
    jobs = "/api/v1/projects/proj-fleet/notebooks/nb-0000000000000003/jobs/job-1/runs/"
    failed = jobs <> "run_" <> String.duplicate("1", 26)
    worked = jobs <> "run_" <> String.duplicate("2", 26)

    opened = send_notebook(:get, failed <> "/html", cookie, "")
    assert opened.status == 200
    assert [_address] = get_resp_header(opened, "link")
    assert_received {:hub, "GET", ^failed, "u_" <> _, _body}

    stopped = %{stage: "export", message: "Cell 3 raised ValueError"}
    assert kept_failure() == stopped

    # Neither a failure recorded after it nor keeping the page again replaces it.
    Notebooks.record_run_failure(@fleet, "run_" <> String.duplicate("1", 26), %{
      "stage" => "timeout",
      "message" => "later"
    })

    assert send_notebook(:get, failed <> "/html", cookie, "").status == 200
    assert kept_failure() == stopped

    # A run that worked asks for no record.
    assert send_notebook(:get, worked <> "/html", cookie, "").status == 200
    refute_received {:hub, "GET", ^worked, _subject, _body}
  end

  # Costly failure: one member deletes, stops or writes over another's
  # notebook work, which the group can no longer use.
  test "members open, copy and run each other's work, and only its maker removes or stops it",
       c do
    cookie = enter!(c.holder)
    theirs = "/api/v1/projects/proj-fleet/notebooks/nb-0000000000000001"
    mine = "/api/v1/projects/proj-fleet/notebooks/nb-0000000000000002"

    for {method, path} <- [
          {:delete, theirs},
          {:patch, theirs <> "/source"},
          {:post, theirs <> "/versions/ver_1/restore"},
          {:post, theirs <> "/editor-session/takeover"},
          {:put, theirs <> "/security-labels"},
          {:delete, theirs <> "/security-labels"},
          {:delete, theirs <> "/deep-links/shared-link"},
          {:delete, theirs <> "/sessions/sess-theirs"},
          {:post, theirs <> "/sessions/sess-theirs/leave"},
          {:delete, theirs <> "/jobs/job-theirs"},
          {:post, theirs <> "/jobs/job-theirs/runs/run_theirs/cancel"},
          {:put, theirs <> "/workspace/files?path=/theirs.csv"},
          {:delete, theirs <> "/workspace/entries?path=data"}
        ] do
      refused = send_notebook(method, path, cookie, "{}")
      assert json_response(refused, 403)["error"]["code"] == "notebooks_maker_only"
      hub_method = method |> Atom.to_string() |> String.upcase()
      bare = path |> String.split("?") |> hd()
      refute_received {:hub, ^hub_method, ^bare, _subject, _body}
    end

    # Editing someone else's notebook opens a sandbox that saves nothing.
    assert send_notebook(:post, theirs <> "/sessions", cookie, "").status == 201
    sessions = theirs <> "/sessions"
    assert_receive {:hub, "POST", ^sessions, "u_" <> _, body}
    assert Jason.decode!(body) == %{"edit_intent" => "temporary"}

    own_sessions = mine <> "/sessions"
    assert send_notebook(:post, own_sessions, cookie, ~s({"mode":"edit"})).status == 201
    assert_receive {:hub, "POST", ^own_sessions, "u_" <> _, ~s({"mode":"edit"})}
    assert send_notebook(:delete, mine, cookie, "").status == 200

    # A file added to someone else's notebook is its adder's to write over and remove.
    files = theirs <> "/workspace/files"
    assert send_notebook(:put, files <> "?path=/mine.csv&create=true", cookie, "a").status == 200
    assert send_notebook(:put, files <> "?path=mine.csv", cookie, "b").status == 200
    assert_receive {:hub, "PUT", ^files, "u_" <> _, "b"}

    entries = theirs <> "/workspace/entries"
    assert send_notebook(:delete, entries <> "?path=/mine.csv", cookie, "").status == 200
    assert_receive {:hub, "DELETE", ^entries, "u_" <> _, _body}

    assert {:ok, []} =
             Notebooks.file_makers_at_or_under(@fleet, "nb-0000000000000001", "mine.csv",
               actor: %System{}
             )

    twice = send_notebook(:put, files <> "?path=a&path=b&create=true", cookie, "a")
    assert json_response(twice, 400)["error"]["code"] == "invalid_request"

    # Another spelling of a file's path would miss its maker, so it never
    # reaches the hub.
    for path <- ["./theirs.csv", "data//theirs.csv", "data/", "data\\theirs.csv", "//theirs.csv"] do
      query = URI.encode_query(%{path: path})
      written = send_notebook(:put, files <> "?" <> query, cookie, "c")
      assert json_response(written, 400)["error"]["code"] == "invalid_request"
      removed = send_notebook(:delete, entries <> "?" <> query, cookie, "")
      assert json_response(removed, 400)["error"]["code"] == "invalid_request"
    end

    refute_received {:hub, _method, _path, _subject, "c"}

    # A folder is its adder's to remove when they made all of it, and never
    # the notebook's maker's while another member's file is in it.
    assert send_notebook(:put, files <> "?path=kept/mine.csv&create=true", cookie, "a").status ==
             200

    assert send_notebook(:delete, entries <> "?path=kept", cookie, "").status == 200

    {:ok, _maker} =
      Notebooks.record_file_maker(@fleet, "nb-0000000000000002", "shared/theirs.csv", "u_other",
        actor: %System{}
      )

    shared = send_notebook(:delete, mine <> "/workspace/entries?path=shared", cookie, "")
    assert json_response(shared, 403)["error"]["code"] == "notebooks_maker_only"

    # A version's saved result is its notebook's maker's to remove.
    version = "ver_" <> String.duplicate("0", 26)

    for notebook <- ["nb-0000000000000001", "nb-0000000000000002"] do
      Notebooks.keep_saved_output!(@fleet, notebook, version, 1, "<p>saved</p>", false,
        actor: %System{}
      )
    end

    kept =
      send_notebook(:delete, Notebooks.result_path("nb-0000000000000001", version, 1), cookie, "")

    assert json_response(kept, 403)["error"]["code"] == "notebooks_maker_only"

    removed =
      send_notebook(:delete, Notebooks.result_path("nb-0000000000000002", version, 1), cookie, "")

    assert removed.status == 204
  end

  # Costly failure: a file a person adds while its maker can't be kept stays
  # as the notebook maker's, out of its adder's reach.
  test "a new file whose maker can't be kept is removed again, a folder is kept", c do
    cookie = enter!(c.holder)
    theirs = "/api/v1/projects/proj-fleet/notebooks/nb-0000000000000001"
    entries = theirs <> "/workspace/entries"

    # Renamed inside the test's own transaction, so keeping the maker fails the
    # way it does while the database can't be reached; the rename ends with the test.
    prefix = Keyfleet.Repo.default_prefix()
    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.notebook_file_makers RENAME TO makers_away")

    added =
      send_notebook(:put, theirs <> "/workspace/files?path=/mine.csv&create=true", cookie, "a")

    made = send_notebook(:post, theirs <> "/workspace/directories", cookie, ~s({"path":"notes/"}))

    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.makers_away RENAME TO notebook_file_makers")

    for answer <- [added, made] do
      assert json_response(answer, 502)["error"]["code"] == "notebooks_unavailable"
    end

    # The folder may have been there already, with other members' files in it.
    assert_received {:hub, "DELETE", ^entries, "u_" <> _, _body}
    refute_received {:hub, "DELETE", ^entries, _subject, _body}
  end

  # Costly failure: a copied or replayed sign-in code opens the notebooks again.
  test "an Open notebooks code works once", c do
    {:ok, entry} = Notebooks.open(c.holder, signed_in!(c.holder), @fleet)
    assert %URI{host: @host, path: "/_keyfleet/enter"} = URI.parse(entry.action)

    first = enter_from(KeyfleetWeb.Endpoint.url(), entry)
    assert first.status == 303
    assert get_resp_header(first, "location") == ["/"]
    cookie = first.resp_cookies["__Host-kf_notebooks"]
    assert %{http_only: true, secure: true, same_site: "Lax", path: "/"} = cookie
    refute Map.has_key?(cookie, :domain)

    again = enter_from(KeyfleetWeb.Endpoint.url(), entry)
    assert again.status == 403
    assert json_response(again, 403)["error"]["code"] == "notebooks_link_used"
    assert again.resp_cookies == %{}
  end

  # Costly failure: a browser that won't keep the notebook sign-in is sent
  # between Keyfleet and the notebooks round and round, spending a code each time.
  test "Keyfleet sends a holder to the notebooks by itself, then waits for a press", c do
    session = SessionAuthorityHelpers.signed_in_session(c.holder.human_account_id)
    open = "/fleets/#{@fleet}/notebooks/open?" <> URI.encode_query(to: "/")

    first = build_conn() |> SessionAuthorityHelpers.init_test_session(session) |> get(open)
    assert html_response(first, 200) =~ ~s[getElementById("notebook-entry").submit()]

    again = first |> recycle() |> get(open)
    page = html_response(again, 200)
    assert page =~ "Open notebooks"
    refute page =~ "submit()"
  end

  # Costly failure: a page on another site, or a pasted link, sends someone's
  # browser a code made for another account, signing them in to the notebooks
  # as that account.
  test "an Open notebooks code is spent only when Keyfleet's page sends it", c do
    {:ok, entry} = Notebooks.open(c.holder, signed_in!(c.holder), @fleet)

    elsewhere = enter_from("https://elsewhere.example", entry)
    assert elsewhere.status == 303

    assert get_resp_header(elsewhere, "location") == [
             KeyfleetWeb.Plugs.NotebookGateway.open_url(@fleet, "/")
           ]

    assert elsewhere.resp_cookies == %{}

    pasted =
      get_notebook(@host, "/_keyfleet/enter?" <> URI.encode_query(code: entry.code, to: "/"), nil)

    assert pasted.status == 403
    assert pasted.resp_cookies == %{}

    here = enter_from(KeyfleetWeb.Endpoint.url(), entry)
    assert here.status == 303
    assert %{value: _cookie} = here.resp_cookies["__Host-kf_notebooks"]
  end

  # Costly failure: a signature header alone makes the site read a large body,
  # before anything about the sender is checked and as often as they like.
  test "a signed request spends its address's budget first and is read only as far as a signature reaches" do
    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)
    Application.put_env(:keyfleet, :api_rate_limit, limit: 1, window_seconds: 3600)
    # Other tests spend the same hourly budget for this address; start unspent.
    :ets.delete_all_objects(Keyfleet.Accounts.RequestRateLimiter)

    too_large = signed_post(String.duplicate("a", 64 * 1024 + 1))
    assert json_response(too_large, 413)["error"]["code"] == "request_too_large"

    past_budget = signed_post(String.duplicate("a", 1_000_000))
    assert json_response(past_budget, 429)["error"]["code"] == "too_many_requests"
    assert [_seconds] = get_resp_header(past_budget, "retry-after")
    refute_received {:hub, _method, _path, _subject, _body}
  end

  # Costly failure: one person's cookie sends the hub as much as a script
  # likes, or starts background runs in a loop.
  test "a person's requests and each run started spend allowances of their own", c do
    limits = Application.fetch_env!(:keyfleet, :limits)
    on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)

    Application.put_env(
      :keyfleet,
      :limits,
      Keyword.merge(limits,
        notebook_requests: [limit: 3, window_seconds: 3600],
        notebook_run_starts: [limit: 1, window_seconds: 3600]
      )
    )

    cookie = enter!(c.holder)
    runs = "/api/v1/projects/proj-fleet/notebooks/nb-1/jobs/job-1/runs"

    assert post_notebook(@host, runs, cookie).status == 201
    assert_receive {:hub, "POST", ^runs, "u_" <> _, _body}

    again = post_notebook(@host, runs, cookie)
    assert json_response(again, 429)["error"]["code"] == "notebook_runs_limit_reached"
    assert [_seconds] = get_resp_header(again, "retry-after")

    assert get_notebook(@host, "/", cookie).status == 200
    assert_receive {:hub, "GET", "/", "u_" <> _, _body}

    past = get_notebook(@host, "/", cookie)
    assert json_response(past, 429)["error"]["code"] == "notebook_requests_limit_reached"
    refute_received {:hub, _method, _path, "u_" <> _, _body}
  end

  # Costly failure: one fleet's notebook sign-in opens another fleet's hub, or
  # a notebook page of one fleet, which runs whatever its authors wrote, changes
  # another fleet's notebooks as a person who holds Keys in both.
  test "a sign-in cookie for one fleet signs no one in on another fleet's host", c do
    cookie = enter!(c.holder)

    refused = get_notebook(@other_host, "/api/v1/me", cookie)
    assert json_response(refused, 401)["error"]["code"] == "notebooks_sign_in"
    assert get_notebook(@other_host, "/", cookie).status == 303
    refute_received {:hub, _method, _path, _subject, _body}

    create = "/api/v1/projects/proj-fleet/notebooks"
    own = Notebooks.url(@fleet, nil)
    other = Notebooks.url(@other_fleet, nil)

    for from <- [
          [{"origin", other}],
          [{"origin", "null"}],
          [{"sec-fetch-site", "same-site"}],
          [{"origin", own}, {"sec-fetch-site", "cross-site"}]
        ] do
      elsewhere = notebook(@host, :post, create, cookie, from)

      assert json_response(elsewhere, 403)["error"]["code"] == "notebooks_other_site",
             inspect(from)

      socket = notebook(@host, :get, "/api/v1/events", cookie, [{"upgrade", "websocket"} | from])
      assert json_response(socket, 403)["error"]["code"] == "notebooks_other_site", inspect(from)
    end

    refute_received {:hub, _method, _path, _subject, _body}

    here =
      notebook(@host, :post, create, cookie, [{"origin", own}, {"sec-fetch-site", "same-origin"}])

    assert here.status == 201
    assert_receive {:hub, "POST", ^create, "u_" <> _, _body}
  end

  # Costly failure: a holder mints a lasting hub credential that skips the key check.
  test "the hub's token routes are refused in every spelling", c do
    cookie = enter!(c.holder)

    for path <- [
          "/api/v1/me/tokens",
          "/api/v1/me/%74okens",
          "/API/v1/me/tokens/scoped",
          "/api/v1//me/tokens",
          "/api/v1/me/oauth-authorizations/x/approve",
          "/api/v1/me/cli-device-authorizations/scoped",
          "/api/cli/v1/token",
          "/api/v1/projects/p/notebooks/n/sync-token/rotate",
          "/mcp",
          "/token",
          "/register"
        ] do
      refused = post_notebook(@host, path, cookie)
      assert refused.status == 403, path
    end

    for path <- ["/api/v1/me/./tokens", "/api/v1/x/../me/tokens", "/api/v1/me/%2e%2e/me/tokens"] do
      assert post_notebook(@host, path, cookie).status == 400, path
    end

    refute_received {:hub, _method, _path, "u_" <> _, _body}
  end

  # Costly failure: another spelling of a route this site checks reaches the
  # hub as that route unchecked, so a fleet opens more sessions than it may or
  # a job runs on a schedule.
  test "an API route spelled with escapes never reaches the hub", c do
    cookie = enter!(c.holder)
    base = "/api/v1/projects/proj-fleet/notebooks/nb-1"

    for {method, path} <- [
          {:post, base <> "/session%73"},
          {:post, base <> "/job%73"},
          {:patch, base <> "/jobs%2Fjob-1"},
          {:get, "/%61pi/v1/projects"}
        ] do
      assert notebook(@host, method, path, cookie).status == 400, path
    end

    refute_received {:hub, _method, _path, "u_" <> _, _body}

    # A notebook page's own address may carry escapes.
    page = "/projects/proj-fleet/notebooks/nb%201"
    assert get_notebook(@host, page, cookie).status == 200
    assert_receive {:hub, "GET", ^page, "u_" <> _, _body}
  end

  # Costly failure: a hub's answer sends a member's browser on to another site
  # from the fleet's own notebook address.
  test "a hub's redirect is passed on only within the fleet's notebooks", c do
    cookie = enter!(c.holder)
    here = Notebooks.url(@fleet, "/projects/proj-fleet")

    for {to, kept} <- [
          {"/projects/proj-fleet", ["/projects/proj-fleet"]},
          {here, [here]},
          {"https://elsewhere.example/", []},
          {"//elsewhere.example/", []},
          {"/\\elsewhere.example/", []},
          {Notebooks.url(@other_fleet, "/"), []}
        ] do
      moved = get_notebook(@host, "/projects/moved?" <> URI.encode_query(to: to), cookie)
      assert moved.status == 302, to
      assert get_resp_header(moved, "location") == kept, to
    end
  end

  # Costly failure: a hub accepts a pass meant for another fleet, another person
  # or one that never runs out; or can't check passes while the site is closed.
  test "a pass names the fleet's hub and the holder, runs out soon, and checks against the published keys",
       c do
    surfaces = Application.fetch_env!(:keyfleet, :app_surfaces)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, surfaces) end)
    Application.put_env(:keyfleet, :app_surfaces, false)

    jwks = build_conn() |> get("/.well-known/hub-jwks.json") |> json_response(200)
    pass = Keyfleet.Notebooks.Pass.mint(@fleet, Notebooks.subject(c.holder))
    [kid] = for %{"kid" => kid} <- jwks["keys"], do: kid
    refute Enum.any?(jwks["keys"], &Map.has_key?(&1, "d"))

    assert %JOSE.JWS{alg: {_ecdsa, :ES256}, fields: %{"kid" => ^kid}} =
             JOSE.JWT.peek_protected(pass)

    assert {true, %JOSE.JWT{fields: claims}, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(hd(jwks["keys"])), ["ES256"], pass)

    subject = "u_#{c.holder.human_account_id}"

    assert %{
             "iss" => "https://keyfleet.ai",
             "aud" => "keyfleet-hub:fibonacci_syndicate",
             "sub" => ^subject,
             "email" => "u_" <> _
           } = claims

    assert claims["email"] == subject <> "@identity.keyfleet.invalid"
    assert claims["exp"] - claims["iat"] <= 300
  end

  # Costly failure: someone who sold their key keeps working in the fleet's
  # notebooks, through a connection already open or the hub's own roster.
  test "a key changing hands closes the old holder's connections and takes them off the hub", c do
    subject = Notebooks.subject(c.holder)
    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, Notebooks.access_topic(@fleet, subject))

    epoch!(1, 2, @buyer_wallet)
    assert_enqueued(worker: Roster, args: %{fleet_id: @fleet})
    assert :ok = perform_job(Roster, %{fleet_id: @fleet})

    assert_receive :notebook_access_ended
    member_path = "/api/v1/projects/proj-fleet/members/" <> subject
    assert_receive {:hub, "DELETE", ^member_path, "kf_provisioner_" <> _, _}
    suspension = "/api/v1/admin/users/#{subject}/suspension"
    assert_receive {:hub, "PUT", ^suspension, "kf_provisioner_" <> _, _}

    buyer = Notebooks.subject(c.buyer)
    assert_receive {:hub, "POST", "/api/v1/projects/proj-fleet/members", _, body}

    assert Jason.decode!(body) == %{
             "email" => buyer <> "@identity.keyfleet.invalid",
             "role" => "editor"
           }
  end

  # Costly failure: while a fleet's ownership is being read again, every
  # ten-minute run leaves one more waiting run behind, each waking every few
  # seconds on the one-at-a-time hub queue.
  test "a run while the fleet's ownership is being read again ends, and leaves the hub alone" do
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))

    assert {:cancel, :ownership_refreshing} = perform_job(Roster, %{fleet_id: @fleet})
    refute_received {:hub, "POST", "/api/v1/projects/proj-fleet/members", _, _}
  end

  # Costly failure: an agent whose shard has run out keeps working in the
  # fleet's notebooks until the next ten-minute check, and a run booked for
  # that moment holds back the run a key changing hands needs now.
  test "a shard issued books a hub run for the moment it runs out" do
    %{expires_at: ends_at} =
      ChainHelpers.issue_shard!(@fleet, 1, "0x" <> String.duplicate("c", 40), 2)

    assert_enqueued(worker: Roster, args: %{fleet_id: @fleet}, scheduled_at: ends_at)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :notebook_hubs)

    epoch!(1, 2, @buyer_wallet)

    assert [%{state: "available"}, %{state: "scheduled", scheduled_at: booked}] =
             [worker: Roster, args: %{fleet_id: @fleet}]
             |> all_enqueued()
             |> Enum.sort_by(& &1.state)

    assert DateTime.compare(DateTime.truncate(booked, :second), ends_at) == :eq
  end

  # Costly failure: a header the signature does not cover changes who an agent
  # is in a fleet's notebooks, or reaches the hub.
  test "an unsigned header such as x-agent-role: admin is accepted and grants nothing" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    epoch!(2, 1, String.downcase(signer.address))

    [plain, extra] =
      for extra <- [%{}, %{"x-agent-role" => "admin"}] do
        request = SignedAgentHelpers.sign(signer, secret, @host, "GET", "/", "")

        %{build_conn() | host: @host, remote_ip: {198, 51, 100, 130}}
        |> then(
          &Enum.reduce(Map.merge(request.headers, extra), &1, fn {name, value}, conn ->
            put_req_header(conn, name, value)
          end)
        )
        |> dispatch(@endpoint, :get, "/", "")
      end

    assert {extra.status, extra.resp_body} == {plain.status, plain.resp_body}

    # A read signs no content-digest; the sign-in server hears every other
    # signed header and nothing else.
    signed_headers = Siwa.Contract.forwarded_headers() -- [Siwa.Contract.body_component()]

    for _sent <- 1..2 do
      assert_receive {:broker_payload, %{"headers" => forwarded}}
      assert Enum.sort(Map.keys(forwarded)) == Enum.sort(signed_headers)
    end
  end

  # Costly failure: a Key-holding agent's signed request is checked against
  # the agent API's own bodies and refused, so agents can't use notebooks.
  test "a Key-holding agent's signed requests reach the hub as that agent, body as sent" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
      )

    subject = Notebooks.agent_subject(profile.id)
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    created = ~s({"name":"orbit.py"})

    for {method, path, body, status} <- [{"GET", "/", "", 200}, {"POST", notebooks, created, 201}] do
      request = SignedAgentHelpers.sign(signer, secret, @host, method, path, body)

      conn =
        Enum.reduce(
          request.headers,
          %{build_conn() | host: @host, remote_ip: {198, 51, 100, 131}},
          fn {name, value}, conn -> put_req_header(conn, name, value) end
        )
        |> dispatch(@endpoint, method, path, body)

      assert conn.status == status
      assert_receive {:hub, ^method, ^path, ^subject, ^body}
    end
  end

  # Costly failure: an agent that signs a notebook read the way it signs a
  # read on the site, with no content-digest, is refused and never reads a
  # notebook's code (Grok Bot, 18 October 2026); and, its answers naming no
  # request, can't cite either one (Grok Bot, 19 October).
  test "a read signed with or without the empty body's digest reads a notebook's code, and names its request" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
      )

    subject = Notebooks.agent_subject(profile.id)
    code = "/api/v1/projects/proj-fleet/notebooks/nb-0123456789abcdef/content"

    for request <- [
          SignedAgentHelpers.sign(signer, secret, @host, "GET", code, nil),
          SignedAgentHelpers.sign_empty_digest(signer, secret, @host, "GET", code)
        ] do
      read = send_signed(request, {198, 51, 100, 132})
      assert read.status == 200
      assert [_named] = get_resp_header(read, "x-request-id")
      assert_receive {:hub, "GET", ^code, ^subject, ""}
    end
  end

  # Costly failure: a notebook request whose body is not the one its signature
  # declares reaches the hub, or a request signed with no body is refused.
  test "a signed request reaches the hub only with the body its content-digest declares, none declaring the empty body" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
      )

    subject = Notebooks.agent_subject(profile.id)
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    body = ~s({"name":"orbit.py"})

    for {method, path, ok} <- [{"GET", "/", 200}, {"POST", notebooks, 201}] do
      cases =
        SignedAgentHelpers.body_cases(
          signer,
          secret,
          @host,
          method,
          path,
          body,
          ~s({"name":"x.py"})
        )

      answers =
        for {name, request} <- cases do
          answer = send_signed(request, {198, 51, 100, 136})

          forwarded =
            receive do
              {:hub, ^method, ^path, ^subject, forwarded} -> forwarded
            after
              0 -> :none
            end

          {name, answer.status, error_code(answer), forwarded}
        end

      SignedAgentHelpers.assert_reported_bytes!(cases)

      assert {method, answers} ==
               {method,
                [
                  {:no_digest_no_body, ok, nil, ""},
                  {:empty_digest_no_body, ok, nil, ""},
                  {:no_digest_real_body, 401, "http_headers_missing", :none},
                  {:real_digest_matching_body, ok, nil, body},
                  {:real_digest_no_body, 401, "http_body_binding_invalid", :none},
                  {:real_digest_different_body, 401, "http_body_binding_invalid", :none}
                ]}
    end
  end

  # Costly failure: an agent's body of exactly the limit, sent in chunks with
  # no length, is refused as too large.
  test "a signed body of exactly 64 KiB reaches the hub however it arrives, and one byte more is refused" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
      )

    subject = Notebooks.agent_subject(profile.id)
    # Served on a real port, so a body arrives in chunks as it does from an agent.
    site = SignedAgentHelpers.serve!(:site, @endpoint)
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    created = ~s({"name":"orbit.py"})
    exact = created <> String.duplicate(" ", 64 * 1024 - byte_size(created))
    over = exact <> " "

    answers =
      for {bytes, sent} <- [
            {exact, exact},
            {exact, Stream.map([exact], & &1)},
            {over, over},
            {over, Stream.map([over], & &1)}
          ] do
        request = SignedAgentHelpers.sign(signer, secret, @host, "POST", notebooks, bytes)

        answer =
          Req.post!(site <> notebooks,
            headers: Map.put(request.headers, "host", @host),
            body: sent,
            retry: false
          )

        forwarded =
          receive do
            {:hub, "POST", ^notebooks, ^subject, forwarded} -> forwarded == exact
          after
            0 -> :none
          end

        {answer.status, answer.body["error"]["code"], forwarded}
      end

    assert answers == [
             {201, nil, true},
             {201, nil, true},
             {413, "request_too_large", :none},
             {413, "request_too_large", :none}
           ]
  end

  # Costly failure: a label the signature doesn't cover changes how the hub
  # reads an agent's body: a JSON body sent as text is read as empty by a
  # session start the door read as JSON, so a maker check is skipped, or an
  # encoding label asks whatever reads the body to unpack bytes nobody signed.
  test "an agent's body reaches the hub typed as this door takes it, never as sent, and an encoded one is refused unread",
       c do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    epoch!(2, 1, String.downcase(signer.address))

    Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
      actor: Keyfleet.PairingHelpers.pair_wallet!(String.downcase(signer.address))
    )

    test = self()
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    file = "/api/v1/projects/proj-fleet/notebooks/nb-0123456789abcdef/workspace/files"

    # The hub as in every other test, telling this one how each notebook
    # request's body was labelled.
    hub =
      server(fn conn ->
        {:ok, body, conn} = read_body(conn)

        if String.starts_with?(conn.request_path, notebooks) do
          labels =
            for {name, _value} = label <- conn.req_headers,
                name in ~w(content-type content-encoding),
                do: label

          send(test, {:labels, conn.method, labels, body})
          json(conn, 201, %{success: true, data: %{}})
        else
          hub_answer(conn, c.holder)
        end
      end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(Notebooks.config(), :fleets, %{@fleet => hub})
    )

    created = ~s({"name":"orbit.py"})

    send_labelled = fn method, path, body, labels ->
      request = SignedAgentHelpers.sign(signer, secret, @host, method, path, body)

      request.headers
      |> Map.drop(["content-type"])
      |> Map.merge(Map.new(labels))
      |> Enum.reduce(
        %{build_conn() | host: @host, remote_ip: {198, 51, 100, 139}},
        fn {name, value}, conn -> put_req_header(conn, name, value) end
      )
      |> dispatch(@endpoint, method, path, body || "")
    end

    encoded =
      send_labelled.("POST", notebooks, created, [
        {"content-type", "application/json"},
        {"content-encoding", "gzip"}
      ])

    assert json_response(encoded, 400)["error"]["code"] == "invalid_request"
    refute_received {:broker_payload, _payload}
    refute_received {:labels, _method, _labels, _body}

    as_json = [{"content-type", "application/json"}]
    as_file = [{"content-type", "application/octet-stream"}]

    for {method, path, body, labels, heard} <- [
          {"POST", notebooks, created, [{"content-type", "text/plain"}], as_json},
          {"PUT", file <> "?path=data.csv&create=true", "a,b\n1,2\n", as_json, as_file},
          {"GET", notebooks, nil, as_json, []}
        ] do
      assert send_labelled.(method, path, body, labels).status == 201
      sent = body || ""
      assert_receive {:labels, ^method, ^heard, ^sent}
    end
  end

  # Costly failure: a content-digest the site can't read, or a signature
  # header sent twice, crashes the notebook host or reaches the hub.
  test "a content-digest that isn't one sha-256 digest, or a header sent twice, is refused and reaches nothing" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    notebooks = "/api/v1/projects/proj-fleet/notebooks"
    body = ~s({"name":"orbit.py"})
    digest = Siwa.Contract.body_component()

    unreadable =
      SignedAgentHelpers.sign_digest(signer, secret, @host, "POST", notebooks, "not-a-digest")

    signed = SignedAgentHelpers.sign(signer, secret, @host, "POST", notebooks, body)

    answers =
      for headers <- [
            Map.to_list(unreadable.headers),
            [{digest, signed.headers[digest]} | Map.to_list(signed.headers)]
          ] do
        answer =
          %{build_conn() | host: @host, remote_ip: {198, 51, 100, 137}, req_headers: headers}
          |> dispatch(@endpoint, :post, notebooks, body)

        {answer.status, error_code(answer)}
      end

    assert answers == [{401, "http_body_binding_invalid"}, {401, "duplicate_proof"}]
    refute_received {:hub, _method, _path, _subject, _body}
  end

  # Costly failure: an agent handed its run's result_url can't read the page
  # it cites (Pira, 14 November 2026): a read of it, signed with or without
  # the empty body's digest, answers Keyfleet's own copy.
  test "an agent reads its run's saved page at result_url with a signed read" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
      actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
    )

    run_id = "run_" <> String.duplicate("0", 26)
    notebook = "nb-0123456789abcdef"

    Notebooks.keep_saved_output!(@fleet, notebook, run_id, 1, "<p>kept</p>", true,
      actor: %System{}
    )

    %URI{host: @host, path: page} = URI.parse(Notebooks.result_url(@fleet, notebook, run_id, 1))

    for request <- [
          SignedAgentHelpers.sign(signer, secret, @host, "GET", page, nil),
          SignedAgentHelpers.sign_empty_digest(signer, secret, @host, "GET", page)
        ] do
      assert html_response(send_signed(request, {198, 51, 100, 134}), 200) == "<p>kept</p>"
    end

    refute_received {:hub, "GET", ^page, _subject, _body}
  end

  # Costly failure: a run's page cleared once its 30 days are past breaks its
  # address with a server error, or answers otherwise than an address whose
  # copy was removed.
  test "a run's page cleared after 30 days answers 404 to a member and to an agent, as a removed one does",
       c do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    epoch!(2, 1, wallet)

    Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
      actor: Keyfleet.PairingHelpers.pair_wallet!(wallet)
    )

    notebook = "nb-0123456789abcdef"
    now = DateTime.to_unix(DateTime.utc_now(), :millisecond)

    [cleared, newest] =
      for {n, days} <- [{1, 40}, {2, 35}] do
        run_id = "run_" <> String.duplicate("#{n}", 26)
        saved_at = now - days * 86_400_000

        Notebooks.keep_saved_output!(@fleet, notebook, run_id, saved_at, "<p>#{n}</p>", false,
          actor: %System{}
        )

        Notebooks.result_path(notebook, run_id, saved_at)
      end

    assert :ok = perform_job(Keyfleet.Notebooks.RunPagePruner, %{})

    cookie = enter!(c.holder)

    assert json_response(send_notebook(:get, cleared, cookie, ""), 404)["error"]["code"] ==
             "notebooks_not_found"

    assert html_response(send_notebook(:get, newest, cookie, ""), 200) == "<p>2</p>"

    request = SignedAgentHelpers.sign(signer, secret, @host, "GET", cleared, "")

    signed =
      Enum.reduce(
        request.headers,
        %{build_conn() | host: @host, remote_ip: {198, 51, 100, 135}},
        fn {name, value}, conn -> put_req_header(conn, name, value) end
      )
      |> dispatch(@endpoint, :get, cleared, "")

    assert json_response(signed, 404)["error"]["code"] == "notebooks_not_found"
    refute_received {:hub, "GET", ^cleared, _subject, _body}
  end

  # Costly failure: an agent that signs over its body but leaves out another
  # signed header is told to add the content-digest it already sends, and
  # goes round in circles; it gets the sign-in server's own refusal instead.
  test "a signed read missing a header other than content-digest gets the sign-in server's own refusal" do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_real_broker!(self(), secret)
    epoch!(2, 1, String.downcase(signer.address))
    code = "/api/v1/projects/proj-fleet/notebooks/nb-0123456789abcdef/content"
    request = SignedAgentHelpers.sign_empty_digest(signer, secret, @host, "GET", code)

    refused =
      send_signed(
        %{request | headers: Map.delete(request.headers, "x-timestamp")},
        {198, 51, 100, 133}
      )

    hint = SignedAgentHelpers.client_hint()

    assert %{"code" => "http_headers_missing", "hint" => ^hint} =
             json_response(refused, 401)["error"]

    refute_received {:hub, _method, _path, _subject, _body}
  end

  # Costly failure: a request that carries a content-digest but no signature is
  # taken for an agent's, spends its address's budget, asks the sign-in server,
  # and turns a person opening a shared link away instead of sending them to
  # sign in.
  test "a request with SIWA headers but no signature is answered as an unsigned one, and spends nothing" do
    SignedAgentHelpers.start_real_broker!(self(), :crypto.strong_rand_bytes(32))
    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)
    Application.put_env(:keyfleet, :api_rate_limit, limit: 1, window_seconds: 3600)
    body = ~s({"name":"orbit.py"})

    send_unsigned = fn method, path, headers ->
      %{
        build_conn()
        | host: @host,
          remote_ip: {198, 51, 100, 138},
          req_headers: [{"content-type", "application/json"} | headers]
      }
      |> dispatch(@endpoint, method, path, body)
    end

    for unsigned <- [
          [{"content-digest", Siwa.content_digest_for_body(body)}],
          [{"x-key-id", @holder_wallet}, {"x-timestamp", "1"}]
        ],
        _again <- 1..2 do
      refused = send_unsigned.(:post, "/api/v1/projects/proj-fleet/notebooks", unsigned)
      assert json_response(refused, 401)["error"]["code"] == "notebooks_sign_in"
      assert send_unsigned.(:get, "/", unsigned).status == 303
    end

    refute_received {:broker_payload, _payload}
    refute_received {:hub, _method, _path, _subject, _body}
  end

  # Costly failure: an agent whose person ended its pairing keeps working in
  # the fleet's notebooks through a connection it already had open.
  test "an agent's open notebook connection closes when its person ends the pairing" do
    wallet = "0x" <> String.duplicate("c", 40)
    epoch!(2, 1, wallet)
    agent = Keyfleet.PairingHelpers.pair_wallet!(wallet)

    open = %{
      fleet_id: @fleet,
      subject: "a_paired",
      holder: {:agent, agent},
      sign_in_topic: nil,
      sign_in_ends_at: DateTime.add(DateTime.utc_now(), 3600)
    }

    assert {:ok, ^open} = NotebookSocket.handle_info(:agents_changed, open)

    person = %RegentAgents.Person{privy_user_id: agent.privy_user_id}
    {:ok, pairing} = RegentAgents.get_my_agent(agent.pairing_id, actor: person)
    :ok = RegentAgents.unpair_agent(pairing, actor: person)

    assert {:stop, :normal, {1008, _reason}, _state} =
             NotebookSocket.handle_info(:agents_changed, open)
  end

  # Costly failure: the gateway abandons a cold start while the hub keeps
  # provisioning, leading the caller to create a second paid runner.
  @tag hub_delay_ms: %{
         {"POST", "/api/v1/projects/proj-fleet/notebooks/nb-cold/sessions"} => 300,
         {"POST", "/api/v1/projects/proj-fleet/notebooks/nb-stuck/sessions"} => 2_500,
         {"GET", "/api/v1/projects/proj-fleet/notebooks/nb-slow"} => 300
       }
  test "a cold session start outlasts the ordinary timeout and is forwarded only once", c do
    cookie = enter!(c.holder)
    assert get_notebook(@host, "/", cookie).status == 200

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.merge(Notebooks.config(), hub_timeout_ms: 100, session_start_timeout_ms: 2_000)
    )

    path = "/api/v1/projects/proj-fleet/notebooks/nb-cold/sessions"
    assert post_notebook(@host, path, cookie).status == 201
    assert_receive {:hub, "POST", ^path, "u_" <> _, _body}
    refute_received {:hub, "POST", ^path, _, _}

    read_path = "/api/v1/projects/proj-fleet/notebooks/nb-slow"
    refused = get_notebook(@host, read_path, cookie)
    assert json_response(refused, 502)["error"]["code"] == "notebooks_unavailable"
    assert_receive {:hub, "GET", ^read_path, "u_" <> _, _body}
    refute_received {:hub, "GET", ^read_path, _, _}

    stuck_path = "/api/v1/projects/proj-fleet/notebooks/nb-stuck/sessions"
    refused = post_notebook(@host, stuck_path, cookie)
    assert json_response(refused, 502)["error"]["code"] == "notebooks_unavailable"
    assert_receive {:hub, "POST", ^stuck_path, "u_" <> _, _body}
    refute_received {:hub, "POST", ^stuck_path, _, _}
  end

  ## The fleet and its people

  defp account!(privy_did, wallet) do
    privy_did
    |> Accounts.register_verified!(wallet, [wallet], actor: %System{})
    |> Human.for_account()
  end

  defp epoch!(token_id, epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end

  # The key's edits restricted or allowed, as the `number`th setting on the chain.
  defp restrict!(token_id, restricted, number) do
    Keys.record_edits_restriction!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        restricted: restricted,
        block_number: 20 + number,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("e#{number}", 32),
        log_index: 0
      },
      actor: %System{}
    )
  end

  ## The notebook host

  # The lineage of a fresh Keyfleet sign-in for `person`.
  defp signed_in!(%Human{human_account_id: account_id}),
    do: SessionAuthorityHelpers.signed_in_session(account_id)["session_lineage"]

  defp enter!(holder, lineage \\ nil) do
    {:ok, entry} = Notebooks.open(holder, lineage || signed_in!(holder), @fleet)
    enter_from(KeyfleetWeb.Endpoint.url(), entry).resp_cookies["__Host-kf_notebooks"].value
  end

  # The notebook host's answer to a sign-in code sent from a page at `origin`.
  defp enter_from(origin, entry) do
    %{build_conn() | host: @host}
    |> put_req_header("origin", origin)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(URI.parse(entry.action).path, URI.encode_query(code: entry.code, to: entry.to))
  end

  defp get_notebook(host, path, cookie), do: notebook(host, :get, path, cookie)

  defp send_notebook(method, path, cookie, body) do
    %{build_conn() | host: @host}
    |> put_req_header("cookie", "__Host-kf_notebooks=" <> cookie)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, body)
  end

  defp post_notebook(host, path, cookie), do: notebook(host, :post, path, cookie)

  defp notebook(host, method, path, cookie, headers \\ []) do
    conn =
      Enum.reduce(
        headers,
        %{build_conn() | host: host},
        &put_req_header(&2, elem(&1, 0), elem(&1, 1))
      )

    conn =
      if cookie, do: put_req_header(conn, "cookie", "__Host-kf_notebooks=" <> cookie), else: conn

    dispatch(conn, @endpoint, method, path, nil)
  end

  # Its own client address, so the budget it spends is not one another test
  # spent first in the same window.
  defp signed_post(body) do
    %{build_conn() | host: @host, remote_ip: {198, 51, 100, 129}}
    |> put_req_header(Siwa.Contract.signature_input_header(), "sig1=()")
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, :post, "/api/v1/projects/proj-fleet/notebooks", body)
  end

  # A request an agent signed, sent from `remote_ip`, its own client address,
  # so the budget it spends is not one another test spent first.
  defp send_signed(request, remote_ip) do
    Enum.reduce(
      request.headers,
      %{build_conn() | host: @host, remote_ip: remote_ip},
      fn {name, value}, conn -> put_req_header(conn, name, value) end
    )
    |> dispatch(@endpoint, request.method, request.path, request.body || "")
  end

  # The code a refusal names, or nil for an answer that is not one.
  defp error_code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _answer -> nil
    end
  end

  ## The hub

  defp hub_answer(%Plug.Conn{method: "GET", request_path: "/api/v1/admin/users"} = conn, holder) do
    json(conn, 200, %{
      success: true,
      data: %{items: [%{id: Notebooks.subject(holder), suspended_at: nil}], next_cursor: nil}
    })
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/members"} = conn,
         holder
       ) do
    json(conn, 200, %{
      success: true,
      data: [
        %{user_id: "kf_provisioner_fibonacci_syndicate", role: "admin"},
        %{user_id: Notebooks.subject(holder), role: "editor"}
      ]
    })
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/sessions"} = conn,
         _holder
       ),
       do: json(conn, 200, %{success: true, data: %{items: [], next_cursor: nil}})

  # Notebook nb-0000000000000001, and everything in it, someone else made.
  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/notebooks/" <> rest} =
           conn,
         holder
       ),
       do: notebook_answer(conn, holder, String.split(rest, "/"))

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/" <> _} = conn,
         _holder
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  defp hub_answer(%Plug.Conn{request_path: "/projects/moved"} = conn, _holder) do
    %{"to" => to} = fetch_query_params(conn).query_params
    conn |> put_resp_header("location", to) |> send_resp(302, "")
  end

  defp hub_answer(conn, _holder), do: json(conn, 200, %{success: true, data: %{}})

  defp notebook_answer(conn, holder, [notebook]) do
    author = if notebook == "nb-0000000000000001", do: "u_other", else: Notebooks.subject(holder)
    json(conn, 200, %{success: true, data: %{meta: %{author: author}}})
  end

  defp notebook_answer(conn, _holder, ["nb-0000000000000001", "sessions", _session]),
    do: json(conn, 200, %{success: true, data: %{user_id: "u_other"}})

  defp notebook_answer(conn, _holder, ["nb-0000000000000001", "jobs", _job]),
    do: json(conn, 200, %{success: true, data: %{created_by: "u_other"}})

  defp notebook_answer(conn, _holder, ["nb-0000000000000001", "jobs", _job, "runs", _run]),
    do: json(conn, 200, %{success: true, data: %{triggered_by: "u_other"}})

  # Notebook nb-0000000000000003's runs: run_1… failed, run_2… worked an hour
  # before, each with its page.
  defp notebook_answer(conn, _holder, [
         "nb-0000000000000003",
         "jobs",
         _job,
         "runs",
         run_id,
         "html"
       ]) do
    {status, made} =
      if String.starts_with?(run_id, "run_1"),
        do: {"failed", "2026-11-15T12:00:00Z"},
        else: {"succeeded", "2026-11-15T11:00:00Z"}

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-marimohub-run-id", run_id)
    |> put_resp_header("x-marimohub-run-status", status)
    |> put_resp_header("x-marimohub-captured-at", made)
    |> send_resp(200, "<p>#{run_id}</p>")
  end

  defp notebook_answer(conn, _holder, ["nb-0000000000000003", "jobs", _job, "runs", run_id]) do
    failure = %{
      stage: "export",
      exit_status: 1,
      message: "Cell 3 raised ValueError",
      excerpt: "ValueError: bad row 7"
    }

    json(conn, 200, %{success: true, data: %{run_id: run_id, status: "failed", failure: failure}})
  end

  defp notebook_answer(conn, _holder, [_notebook, "workspace", "entries"]) do
    items = entries(fetch_query_params(conn).query_params["path"])
    json(conn, 200, %{success: true, data: %{items: items}})
  end

  defp notebook_answer(conn, _holder, _other), do: json(conn, 200, %{success: true, data: %{}})

  defp entries("data"), do: [%{path: "/data/theirs.csv", kind: "file"}]
  defp entries("kept"), do: [%{path: "/kept/mine.csv", kind: "file"}]
  defp entries("shared"), do: [%{path: "/shared/theirs.csv", kind: "file"}]
  defp entries(_file), do: []

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp subject(pass), do: JOSE.JWT.peek_payload(pass).fields["sub"]

  # How the newest kept run page of nb-0000000000000003 says its run failed.
  defp kept_failure do
    {:ok, [kept]} =
      Notebooks.newest_run_outputs(@fleet, ["nb-0000000000000003"], actor: %System{})

    kept.failure
  end

  defp server(answer) do
    pid =
      start_supervised!(
        {Bandit,
         plug: fn conn, _opts -> answer.(conn) end,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end
end
