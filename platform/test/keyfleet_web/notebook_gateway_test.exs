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
  alias Keyfleet.{ChainHelpers, Fleets, Keys, Notebooks}
  alias Keyfleet.Notebooks.Roster
  alias KeyfleetWeb.SessionAuthorityHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @host "fibonacci-syndicate.notebooks.localhost"
  @other_host "fibonacci-cascade.notebooks.localhost"
  @holder_wallet "0x" <> String.duplicate("a", 40)
  @buyer_wallet "0x" <> String.duplicate("b", 40)

  setup do
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
        hub_answer(conn, holder)
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(notebooks, :fleets, %{@fleet => hub, @other_fleet => hub})
    )

    Notebooks.record_hub!(@fleet, "proj-fleet", actor: %System{})
    Notebooks.record_hub!(@other_fleet, "proj-other", actor: %System{})

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

    {:ok, _person, topic} = Notebooks.person(sign_in, c.holder.human_account_id)

    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

    signed_out =
      build_conn()
      |> SessionAuthorityHelpers.init_test_session(session)
      |> delete("/auth/privy/session")

    assert json_response(signed_out, 200) == %{"ok" => true}
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

    refused = get_notebook(@host, "/", cookie)
    assert json_response(refused, 401)["error"]["code"] == "notebooks_sign_in"
    assert Notebooks.open(c.holder, lineage, @fleet) == {:error, :signed_out}
  end

  # Costly failure: a copied or replayed sign-in link opens the notebooks again.
  test "an Open notebooks link works once", c do
    {:ok, url} = Notebooks.open(c.holder, signed_in!(c.holder), @fleet)
    %URI{host: @host, path: "/_keyfleet/enter", query: query} = URI.parse(url)

    first = get_notebook(@host, "/_keyfleet/enter?" <> query, nil)
    assert first.status == 303
    assert get_resp_header(first, "location") == ["/"]
    cookie = first.resp_cookies["__Host-kf_notebooks"]
    assert %{http_only: true, secure: true, same_site: "Lax", path: "/"} = cookie
    refute Map.has_key?(cookie, :domain)

    again = get_notebook(@host, "/_keyfleet/enter?" <> query, nil)
    assert again.status == 403
    assert json_response(again, 403)["error"]["code"] == "notebooks_link_used"
    assert again.resp_cookies == %{}
  end

  # Costly failure: one fleet's notebook sign-in opens another fleet's hub.
  test "a sign-in cookie for one fleet signs no one in on another fleet's host", c do
    cookie = enter!(c.holder)

    refused = get_notebook(@other_host, "/", cookie)
    assert refused.status == 401
    assert json_response(refused, 401)["error"]["code"] == "notebooks_sign_in"
    refute_received {:hub, _method, _path, _subject, _body}
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

  # Costly failure: an agent whose shard has run out keeps working in the
  # fleet's notebooks until the next ten-minute check, and a run booked for
  # that moment holds back the run a key changing hands needs now.
  test "a shard issued books a hub run for the moment it runs out" do
    %{expires_at: ends_at} =
      ChainHelpers.issue_shard!(@fleet, 1, "0x" <> String.duplicate("c", 40), 2)

    assert_enqueued(worker: Roster, args: %{fleet_id: @fleet}, scheduled_at: ends_at)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :notebook_hubs)

    epoch!(1, 2, @buyer_wallet)

    assert [%{state: "available"}, %{state: "scheduled", scheduled_at: booked}] =
             [worker: Roster, args: %{fleet_id: @fleet}]
             |> all_enqueued()
             |> Enum.sort_by(& &1.state)

    assert DateTime.compare(DateTime.truncate(booked, :second), ends_at) == :eq
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

  ## The notebook host

  # The lineage of a fresh Keyfleet sign-in for `person`.
  defp signed_in!(%Human{human_account_id: account_id}),
    do: SessionAuthorityHelpers.signed_in_session(account_id)["session_lineage"]

  defp enter!(holder, lineage \\ nil) do
    {:ok, url} = Notebooks.open(holder, lineage || signed_in!(holder), @fleet)
    %URI{path: path, query: query} = URI.parse(url)
    entered = get_notebook(@host, path <> "?" <> query, nil)
    entered.resp_cookies["__Host-kf_notebooks"].value
  end

  defp get_notebook(host, path, cookie), do: notebook(host, :get, path, cookie)
  defp post_notebook(host, path, cookie), do: notebook(host, :post, path, cookie)

  defp notebook(host, method, path, cookie) do
    conn = %{build_conn() | host: host}

    conn =
      if cookie, do: put_req_header(conn, "cookie", "__Host-kf_notebooks=" <> cookie), else: conn

    dispatch(conn, @endpoint, method, path, nil)
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
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/" <> _} = conn,
         _holder
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  defp hub_answer(conn, _holder), do: json(conn, 200, %{success: true, data: %{}})

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp subject(pass), do: JOSE.JWT.peek_payload(pass).fields["sub"]

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
