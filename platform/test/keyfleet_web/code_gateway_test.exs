defmodule KeyfleetWeb.CodeGatewayTest do
  # The fleets' code is reached only through this site. Each test names the
  # costly failure it guards against; the code store is a local server that
  # records every request it gets.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.{Agent, Human, System}
  alias Keyfleet.{ChainHelpers, Code, Fleets, Keys}
  alias Keyfleet.Code.Setup
  alias KeyfleetWeb.{CodePassword, SessionAuthorityHelpers}

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @host "code.localhost"
  @owner "did:key:z6MkfleetOwner"
  @holder_wallet "0x" <> String.duplicate("a", 40)
  @buyer_wallet "0x" <> String.duplicate("b", 40)
  @agent_wallet "0x" <> String.duplicate("c", 40)
  @old String.duplicate("1", 40)
  @new String.duplicate("2", 40)

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    epoch!(1, 1, @holder_wallet)

    holder = account!("did:privy:code-holder", @holder_wallet)
    buyer = account!("did:privy:code-buyer", @buyer_wallet)

    test = self()

    store =
      server(fn conn ->
        {:ok, body, conn} = read_body(conn, length: 200_000_000)
        ["Bearer " <> pass] = get_req_header(conn, "authorization")
        send(test, {:store, conn.method, conn.request_path, claims(pass), body})
        store_answer(conn)
      end)

    code = Application.fetch_env!(:keyfleet, :code)
    on_exit(fn -> Application.put_env(:keyfleet, :code, code) end)
    Application.put_env(:keyfleet, :code, Keyword.put(code, :node, store))

    Code.record_repository!(@fleet, @owner, actor: %System{})
    Code.record_repository!(@other_fleet, @owner, actor: %System{})

    %{holder: holder, buyer: buyer}
  end

  # Costly failure: someone without a key reads or changes a fleet's code, or
  # keeps doing so after selling the key.
  test "only a holder's password reaches the store, and a key changing hands ends it at once",
       c do
    assert CodePassword.for_person(c.buyer, signed_in!(c.buyer), @fleet) ==
             {:error, :not_holder}

    password = person_password!(c.holder)
    answered = git(:get, "/#{@fleet}.git/info/refs?service=git-receive-pack", password)
    assert answered.status == 200
    assert answered.resp_body =~ "# service=git-receive-pack"

    info_refs = "/#{@owner}/#{@fleet}/info/refs"
    assert_receive {:store, "GET", ^info_refs, claims, ""}

    assert %{
             "iss" => "https://keyfleet.ai",
             "aud" => "keyfleet-code",
             "fleet" => @fleet,
             "scope" => "push",
             "sub" => "did:pkh:eip155:8453:" <> @holder_wallet
           } = claims

    assert claims["exp"] - claims["iat"] <= 600

    epoch!(1, 2, @buyer_wallet)
    Code.end_access(@fleet)
    # The site's own PubSub delivers the end to every node; this one is told first.
    :sys.get_state(Keyfleet.AccessCache)

    refused = git(:get, "/#{@fleet}.git/info/refs?service=git-upload-pack", password)
    assert refused.status == 403
    assert refused.resp_body =~ "Only holders of this fleet's keys"
    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: a password for one fleet, or none, opens another fleet's code.
  test "git without a password is asked for one, and one fleet's password opens no other fleet",
       c do
    asked = git(:get, "/#{@fleet}.git/info/refs?service=git-upload-pack", nil)
    assert asked.status == 401
    assert get_resp_header(asked, "www-authenticate") == [~s(Basic realm="KeyFleet code")]

    password = person_password!(c.holder)
    other = git(:get, "/#{@other_fleet}.git/info/refs?service=git-upload-pack", password)
    assert other.status == 401

    forged = git(:get, "/#{@fleet}.git/info/refs?service=git-upload-pack", password <> "x")
    assert forged.status == 401

    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: a holder reaches a store address beyond git's own, where a
  # pass would let them make, list or read other repositories.
  test "only git's three requests reach the store", c do
    password = person_password!(c.holder)

    for {method, path} <- [
          {:get, "/#{@fleet}.git/info/refs"},
          {:get, "/#{@fleet}.git/info/refs?service=git-upload-archive"},
          {:get, "/#{@fleet}/info/refs?service=git-upload-pack"},
          {:post, "/#{@fleet}.git/git-upload-archive"},
          {:get, "/#{@fleet}.git/git-upload-pack"},
          {:post, "/api/v1/repos"},
          {:get, "/api/v1/repos/#{@owner}/#{@fleet}/commits"},
          {:get, "/#{@fleet}.git/HEAD"},
          {:get, "/..%2F#{@fleet}.git/info/refs?service=git-upload-pack"},
          {:get, "/"}
        ] do
      assert git(method, path, password).status == 404, path
    end

    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: a push is credited to the wrong key or wallet, a refused
  # branch shows as sent, or the pack is changed on its way.
  test "an agent's push reaches the store whole and only what it accepted is recorded" do
    ChainHelpers.issue_shard!(@fleet, 1, @agent_wallet, 2)
    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, Code.topic(@fleet))

    agent = %Agent{
      wallet_address: @agent_wallet,
      chain_id: 1,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    {:ok, %{password: password}} = CodePassword.for_agent(agent, @fleet)

    pack = "PACK" <> :crypto.strong_rand_bytes(3_000_000)

    body =
      pkt("#{@old} #{@new} refs/heads/main\0 report-status side-band-64k agent=git/2.47\n") <>
        pkt("#{@old} #{@new} refs/heads/refused\n") <>
        pkt("#{@old} #{String.duplicate("0", 40)} refs/heads/gone\n") <> "0000" <> pack

    pushed = git(:post, "/#{@fleet}.git/git-receive-pack", password, body)
    assert pushed.status == 200

    receive_pack = "/#{@owner}/#{@fleet}/git-receive-pack"
    assert_receive {:store, "POST", ^receive_pack, claims, ^body}
    assert claims["sub"] == "did:pkh:eip155:8453:" <> @agent_wallet
    assert pushed.resp_body == report()

    assert_receive {:code_pushed, @fleet}

    assert [%{token_id: 1, wallet: @agent_wallet, ref: "refs/heads/main", head: @new}] =
             Code.recent_pushes!(@fleet)
  end

  # Costly failure: a fleet's code is never set up, or set up twice.
  test "the first ask sets the fleet's repository up, and setting it up again is safe", c do
    fleet = "fleet_tech_classic"
    ChainHelpers.seed_cursor!(fleet)
    epoch!(fleet, 1, 1, @holder_wallet)

    {:ok, %{password: password}} =
      CodePassword.for_person(c.holder, signed_in!(c.holder), fleet)

    assert_enqueued(worker: Setup, args: %{fleet_id: fleet})
    waiting = git(:get, "/#{fleet}.git/info/refs?service=git-upload-pack", password)
    assert waiting.status == 503

    Req.Test.stub(Code.NodeClient, fn conn ->
      {:ok, body, conn} = read_body(conn)
      ["Bearer " <> pass] = get_req_header(conn, "authorization")
      send(self(), {:create, claims(pass), Jason.decode!(body)})
      Req.Test.json(conn, %{"name" => fleet, "owner_did" => @owner})
    end)

    assert :ok = perform_job(Setup, %{fleet_id: fleet})
    assert :ok = perform_job(Setup, %{fleet_id: fleet})
    assert_received {:create, %{"scope" => "create", "fleet" => ^fleet}, %{"name" => ^fleet}}
    refute_received {:create, _claims, _body}

    assert git(:get, "/#{fleet}.git/info/refs?service=git-upload-pack", password).status == 200
  end

  ## The fleet and its people

  defp account!(privy_did, wallet) do
    privy_did
    |> Accounts.register_verified!(wallet, [wallet], actor: %System{})
    |> Human.for_account()
  end

  defp epoch!(fleet_id \\ @fleet, token_id, epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <>
            Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}/#{epoch}"),
              case: :lower
            ),
        log_index: 0
      },
      actor: %System{}
    )
  end

  defp signed_in!(%Human{human_account_id: account_id}),
    do: SessionAuthorityHelpers.signed_in_session(account_id)["session_lineage"]

  defp person_password!(person) do
    {:ok, %{password: password}} = CodePassword.for_person(person, signed_in!(person), @fleet)
    password
  end

  ## Git, through the code host

  defp git(method, path, password, body \\ nil) do
    conn = %{build_conn() | host: @host}

    conn =
      if password,
        do:
          put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("git", password)),
        else: conn

    conn =
      if body,
        do: put_req_header(conn, "content-type", "application/x-git-receive-pack-request"),
        else: conn

    dispatch(conn, @endpoint, method, path, body)
  end

  ## The store

  defp store_answer(%Plug.Conn{method: "GET", request_path: "/" <> _} = conn) do
    service = conn |> fetch_query_params() |> Map.get(:query_params) |> Map.get("service")

    conn
    |> put_resp_content_type("application/x-#{service}-advertisement", nil)
    |> send_resp(200, pkt("# service=#{service}\n") <> "0000")
  end

  defp store_answer(%Plug.Conn{method: "POST"} = conn) do
    conn
    |> put_resp_content_type("application/x-git-receive-pack-result", nil)
    |> send_resp(200, report())
  end

  # The store's report: main done, one branch refused, the deleted one done.
  defp report do
    inner =
      pkt("unpack ok\n") <>
        pkt("ok refs/heads/main\n") <>
        pkt("ng refs/heads/refused non-fast-forward\n") <>
        pkt("ok refs/heads/gone\n") <> "0000"

    pkt(<<2>> <> "Resolving deltas: 100%\n") <> pkt(<<1>> <> inner) <> "0000"
  end

  defp pkt(line),
    do: String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0") <> line

  defp claims(pass), do: JOSE.JWT.peek_payload(pass).fields

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
