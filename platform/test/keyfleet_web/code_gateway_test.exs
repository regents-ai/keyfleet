defmodule KeyfleetWeb.CodeGatewayTest do
  # The fleets' code is reached only through this site. Each test names the
  # costly failure it guards against; the code store is a local server that
  # records every request it gets.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo
  use ExUnitProperties

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{ChainHelpers, Code, Fleets, Keys}
  alias Keyfleet.Code.Setup
  alias KeyfleetWeb.{CodePassword, SessionAuthorityHelpers, SignedAgentHelpers}

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @host "code.localhost"
  # The user name in the address a fleet's workspace gives a person.
  @user "holder"
  @owner "did:key:z6MkfleetOwner"
  @holder_wallet "0x" <> String.duplicate("a", 40)
  @buyer_wallet "0x" <> String.duplicate("b", 40)

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
    assert refused.resp_body =~ "Only holders of this fleet's Keys"
    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: a password for one fleet, or none, opens another fleet's code.
  test "git without a password is asked for one, and one fleet's password opens no other fleet",
       c do
    asked = git(:get, "/#{@fleet}.git/info/refs?service=git-upload-pack", nil)
    assert asked.status == 401
    assert get_resp_header(asked, "www-authenticate") == [~s(Basic realm="Keyfleet code")]

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

  # Costly failure: git asks a person for a user name that nothing checks.
  test "the address a person copies names the user, so git asks only for the password" do
    assert %URI{userinfo: @user, host: @host, path: "/#{@fleet}.git"} =
             URI.parse(Code.clone_url(@fleet))
  end

  # Costly failure: a person opens the address their workspace shows in a
  # browser and is told there is no code there.
  test "a browser opening a fleet's address is sent to the fleet's code on the site" do
    opened = git(:get, "/#{@fleet}.git", nil)
    assert opened.status == 302

    assert get_resp_header(opened, "location") ==
             [KeyfleetWeb.Endpoint.url() <> Code.files_path(@fleet, "")]

    assert git(:get, "/fleet_nobody_made.git", nil).status == 404
    assert git(:get, "/#{@fleet}", nil).status == 404
    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: one wallet pushes to a fleet's code as often as a script
  # can, each push up to `max_pack_bytes`.
  test "each push spends its wallet's allowance in the fleet, and copying spends none", c do
    limits = Application.fetch_env!(:keyfleet, :limits)
    on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)

    Application.put_env(
      :keyfleet,
      :limits,
      Keyword.put(limits, :code_pushes, limit: 1, window_seconds: 3600)
    )

    # Other tests may push as the same wallet in this window; start unspent.
    :ets.delete_all_objects(Keyfleet.Accounts.RequestRateLimiter)

    password = person_password!(c.holder)
    push = "/#{@fleet}.git/git-receive-pack"

    assert git(:post, push, password, "0000").status == 200
    assert_receive {:store, "POST", _path, _claims, "0000"}

    refused = git(:post, push, password, "0000")
    assert refused.status == 429
    assert [_seconds] = get_resp_header(refused, "retry-after")
    refute_received {:store, "POST", _path, _claims, _body}

    assert git(:get, "/#{@fleet}.git/info/refs?service=git-receive-pack", password).status == 200
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

  ## What a push sends

  test "an agent's push the store took is its latest contribution to the fleet" do
    agent = key_holding_agent!(4)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Pusher", declared_harness: "local"},
        actor: agent.actor
      )

    command =
      String.duplicate("0", 40) <>
        " " <> String.duplicate("5", 40) <> " refs/heads/main\0report-status side-band-64k\n"

    assert signed(agent, "/#{@fleet}.git/git-receive-pack", pkt(command) <> "0000").status == 200
    assert Keyfleet.Agents.get_check_in!(profile.id, @fleet).last_contribution_kind == :code
  end

  # Costly failure: an agent's push reaches the store changed, or not at all.
  test "a Key-holding agent's push reaches the store as the exact bytes it signed" do
    agent = key_holding_agent!(2)
    pack = :crypto.strong_rand_bytes(150_000)

    pushed = signed(agent, "/#{@fleet}.git/git-receive-pack", pack)

    assert pushed.status == 200
    receive_pack = "/#{@owner}/#{@fleet}/git-receive-pack"
    sub = "did:pkh:eip155:8453:" <> agent.wallet
    assert_receive {:store, "POST", ^receive_pack, %{"sub" => ^sub}, ^pack}
    assert spooled() == []
  end

  # Costly failure: bytes changed after an agent signed them reach the store
  # under its name.
  property "a body differing from the signed one by any byte reaches nothing, and its file is gone" do
    agent = key_holding_agent!(3)

    check all(
            pack <- binary(min_length: 1, max_length: 200_000),
            at <- integer(0..(byte_size(pack) - 1)),
            max_runs: 20
          ) do
      <<before::binary-size(^at), byte, rest::binary>> = pack
      changed = before <> <<Bitwise.bxor(byte, 1)>> <> rest

      refused = signed(agent, "/#{@fleet}.git/git-receive-pack", pack, changed)

      assert refused.status == 400
      assert refused.resp_body =~ "isn't what this request's signature covers"
      refute_received {:store, _method, _path, _claims, _body}
      assert spooled() == []
    end
  end

  # Costly failure: one push fills the site's disk or memory.
  test "a push past the limit is refused with 413, reaches nothing, and its file is gone", c do
    put_code(max_pack_bytes: 100_000)
    password = person_password!(c.holder)

    refused =
      git(:post, "/#{@fleet}.git/git-receive-pack", password, :binary.copy(<<0>>, 100_001))

    assert refused.status == 413
    refute_received {:store, _method, _path, _claims, _body}
    assert spooled() == []
  end

  # Costly failure: a sender trickling a push a byte at a time holds the
  # site's connections for ever. Each tiny piece arrives well inside the
  # wait for the next read, so only the whole body's deadline ends it.
  @tag :capture_log
  test "a push trickled a byte at a time is cut off at the deadline and reaches nothing", c do
    put_code(body_idle_ms: 500, body_timeout_ms: 1_000)
    password = person_password!(c.holder)
    socket = open_site!()

    :ok =
      :gen_tcp.send(socket, [
        "POST /#{@fleet}.git/git-receive-pack HTTP/1.1\r\n",
        "host: #{@host}\r\n",
        "authorization: #{Plug.BasicAuth.encode_basic_auth("git", password)}\r\n",
        "content-type: application/x-git-receive-pack-request\r\n",
        "transfer-encoding: chunked\r\n\r\n"
      ])

    started = Elixir.System.monotonic_time(:millisecond)
    assert trickle(socket, 40) == :cut_off
    assert Elixir.System.monotonic_time(:millisecond) - started < 3_000

    refute_received {:store, _method, _path, _claims, _body}
    :sys.get_state(Plug.Upload)
    assert spooled() == []
  end

  # Costly failure: a sender that stops partway holds a connection for as
  # long as the whole body may take.
  @tag :capture_log
  test "a push that stops partway is answered 408 once a read has waited too long", c do
    put_code(body_idle_ms: 500)
    password = person_password!(c.holder)
    socket = open_site!()

    :ok =
      :gen_tcp.send(socket, [
        "POST /#{@fleet}.git/git-receive-pack HTTP/1.1\r\n",
        "host: #{@host}\r\n",
        "authorization: #{Plug.BasicAuth.encode_basic_auth("git", password)}\r\n",
        "content-type: application/x-git-receive-pack-request\r\n",
        "content-length: 1000\r\n\r\n",
        :binary.copy("x", 10)
      ])

    assert {:ok, "HTTP/1.1 408" <> _answer} = :gen_tcp.recv(socket, 0, 3_000)
    refute_received {:store, _method, _path, _claims, _body}
  end

  # Costly failure: a large push on a slow link uploads in full, then fails
  # because the store's pass ran out while it arrived.
  test "a push slower than a pass lasts reaches the store with a pass made once it is in", c do
    password = person_password!(c.holder)
    socket = open_site!()

    :ok =
      :gen_tcp.send(socket, [
        "POST /#{@fleet}.git/git-receive-pack HTTP/1.1\r\n",
        "host: #{@host}\r\n",
        "authorization: #{Plug.BasicAuth.encode_basic_auth("git", password)}\r\n",
        "content-type: application/x-git-receive-pack-request\r\n",
        "content-length: 4\r\n\r\n",
        "00"
      ])

    Process.sleep(2_100)
    finished = Elixir.System.os_time(:second)
    :ok = :gen_tcp.send(socket, "00")

    assert {:ok, "HTTP/1.1 200" <> _answer} = :gen_tcp.recv(socket, 0, 5_000)
    assert_receive {:store, "POST", _path, claims, "0000"}
    assert claims["iat"] >= finished
  end

  # Costly failure: the site can't record a push the store took, and git is
  # told the push failed though it landed.
  test "a push the site can't record still gets the store's answer, and the failure is saved",
       c do
    password = person_password!(c.holder)

    command =
      String.duplicate("0", 40) <>
        " " <> String.duplicate("5", 40) <> " refs/heads/main\0report-status side-band-64k\n"

    # Renamed inside the test's own transaction, so recording fails the way it
    # does while the database can't be reached; the rename ends with the test.
    prefix = Keyfleet.Repo.default_prefix()
    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.code_pushes RENAME TO code_pushes_away")

    pushed = git(:post, "/#{@fleet}.git/git-receive-pack", password, pkt(command) <> "0000")

    Keyfleet.Repo.query!("ALTER TABLE #{prefix}.code_pushes_away RENAME TO code_pushes")

    assert pushed.status == 200
    assert pushed.resp_body == report()
    assert_receive {:store, "POST", _path, _claims, _body}
    assert spooled() == []

    assert Keyfleet.Repo.exists?(
             from(error in ErrorTracker.Error,
               where: like(error.reason, ^"A push to #{@fleet} could not be recorded%")
             )
           )
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
          put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(@user, password)),
        else: conn

    conn =
      if body,
        do: put_req_header(conn, "content-type", "application/x-git-receive-pack-request"),
        else: conn

    dispatch(conn, @endpoint, method, path, body)
  end

  # A paired agent whose own wallet holds Key `token_id`, and the sign-in server
  # that checks its requests.
  defp key_holding_agent!(token_id) do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    wallet = String.downcase(signer.address)
    actor = Keyfleet.PairingHelpers.pair_wallet!(wallet)
    epoch!(token_id, 1, wallet)
    %{signer: signer, secret: secret, wallet: wallet, actor: actor}
  end

  # `signed` is what the agent signed; `sent` is what arrives. Each agent
  # sends from its own address, so no other test spent its budget.
  defp signed(agent, path, signed, sent \\ nil) do
    request = SignedAgentHelpers.sign(agent.signer, agent.secret, "POST", path, signed)

    %{build_conn() | host: @host, remote_ip: {198, 51, 100, 140}}
    |> then(
      &Enum.reduce(request.headers, &1, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
    )
    |> dispatch(@endpoint, :post, path, sent || signed)
  end

  defp put_code(settings),
    do:
      Application.put_env(
        :keyfleet,
        :code,
        Keyword.merge(Application.fetch_env!(:keyfleet, :code), settings)
      )

  # The files this run's bodies are written to while they arrive. Plug ends each
  # VM's folders with its own random suffix, so another test run on the same
  # machine never counts.
  defp spooled do
    {roots, suffix} = :persistent_term.get(Plug.Upload)
    Enum.flat_map(roots, &Path.wildcard(Path.join([&1, "plug-*-#{suffix}", "keyfleet-code-*"])))
  end

  # The site, served on a real socket, so a body can arrive slowly.
  defp open_site! do
    site = SignedAgentHelpers.serve!(:site, @endpoint)
    %URI{port: port} = URI.parse(site)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    socket
  end

  # Sends one byte every 100 ms until the site closes the connection or the
  # bytes run out.
  defp trickle(_socket, 0), do: :still_open

  defp trickle(socket, left) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:error, :timeout} ->
        case :gen_tcp.send(socket, "1\r\nx\r\n") do
          :ok -> trickle(socket, left - 1)
          {:error, _closed} -> :cut_off
        end

      {:error, :closed} ->
        :cut_off
    end
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
