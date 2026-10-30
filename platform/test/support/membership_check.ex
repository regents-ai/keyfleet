defmodule Keyfleet.MembershipCheck do
  @moduledoc """
  Checks that membership moves everywhere a fleet keeps something for its
  members, its rooms, workspace, notebooks and code, when it changes in one of
  three ways, and prints a line for each thing it checked:

    * a Key changes hands: its old holder's agent is refused everywhere with
      each place's own answer, the notebook connection it had open closes, the
      old holder's own notebook sign-in and code password stop working,
      `Keyfleet.Access` counts the new holder in and the old one out, and the
      new holder's agent gets in everywhere;
    * a person ends their agent's pairing: the agent's open notebook
      connection closes by itself, and everything it asks after that is
      refused `agent_not_paired`, in words that send the person to this site;
    * an agent whose person holds a Key of another fleet is refused on this
      one, and let in on its own.

  `mix keyfleet.check_membership` runs it under the test configuration, as its
  own local server, on a database of its own that it empties first. The chain
  is the test chain, and Keys are sold and moved through `Keyfleet.BrowserChain`,
  which drives the real chain reader, so the code's admissions end and the
  notebook hub job is queued as they are when a Key moves on Base. Oban runs no
  queue under test, so the check runs that job itself after each change. The
  sign-in server, the fleets' notebook hubs and the code store are stand-ins it
  serves on free local ports. Every request reaches the site over HTTPS at
  `localhost`, naming the notebook or code host it is for.

  What it writes commits: the test pool is the SQL sandbox, which in its
  default automatic mode gives each process an ordinary connection, and an
  ended pairing is announced through `pg_notify`, which Postgres delivers only
  on commit. Membership counts only on a chain reading under two minutes old
  (`Keyfleet.Chain.fresh?/1`), so each case reads the chain first; a run takes
  well under two minutes.
  """

  import Plug.Conn

  alias Keyfleet.{
    Actors,
    BrowserChain,
    Code,
    LocalDatabaseFixture,
    Notebooks,
    PairingHelpers,
    Projects,
    Rooms,
    WorkspaceFixtures
  }

  alias KeyfleetWeb.{
    CodePassword,
    NotebookSocket,
    Refusal,
    SessionAuthorityHelpers,
    SignedAgentHelpers
  }

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @store_owner "did:key:z6MkMembershipCheck"
  @cookie "__Host-kf_notebooks"
  @close_within_ms 10_000
  @answer_within_ms 5_000

  defmodule HubSocket do
    @moduledoc "A stand-in hub's end of a notebook connection: it takes every frame, stays open."
    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in(_frame, state), do: {:ok, state}

    @impl WebSock
    def handle_info(_message, state), do: {:ok, state}
  end

  @doc """
  Starts the site from an empty database, runs the three cases and prints a
  line for each check, then a count. Raises when any check failed.
  """
  def run! do
    start_site!()
    c = serve!()
    furnish!()

    results = transfer(c) ++ revocation(c) ++ other_fleet(c)
    failed = Enum.count(results, &(&1 == :fail))
    IO.puts("\n#{length(results)} checks, #{failed} failed")
    if failed > 0, do: Mix.raise("#{failed} of #{length(results)} membership checks failed")
    :ok
  end

  ## The cases

  defp transfer(c) do
    read_chain!()
    holder = pair!()
    buyer = pair!()
    key = BrowserChain.sell!(@fleet, holder.wallet)

    lineage = signed_in!(holder)
    cookie = notebook_cookie(c, holder, lineage)
    own_password = person_password(holder, lineage)
    socket = open_socket(c, holder, @fleet)

    before = [
      admission("transfer: holder's agent reads a members-only room", room(c, holder, @fleet)),
      admission("transfer: holder's agent reads the workspace", workspace(c, holder, @fleet)),
      admission(
        "transfer: holder's agent is let into the notebooks",
        notebooks(c, holder, @fleet)
      ),
      line("transfer: holder's agent opens a notebook connection", opened(socket)),
      admission("transfer: git lets the holder's agent in", agent_git(c, holder, @fleet)),
      admission(
        "transfer: holder opens the notebooks with their sign-in",
        notebook_page(c, cookie)
      ),
      admission(
        "transfer: git lets the holder in with their own password",
        git(c, @fleet, own_password)
      ),
      line("transfer: Keyfleet.Access counts the holder a member", member(holder, true)),
      line("transfer: Keyfleet.Access does not count the buyer a member", member(buyer, false)),
      refusal(
        "transfer: buyer's agent refused in rooms",
        room(c, buyer, @fleet),
        403,
        "not_a_member"
      ),
      refusal(
        "transfer: buyer's agent refused the workspace",
        workspace(c, buyer, @fleet),
        403,
        "workspace_members_only"
      ),
      refusal(
        "transfer: buyer's agent refused the notebooks",
        notebooks(c, buyer, @fleet),
        403,
        "notebooks_not_holder"
      ),
      git_refusal(
        "transfer: git refuses the buyer's agent",
        agent_git(c, buyer, @fleet),
        403,
        "code_not_holder"
      )
    ]

    :ok = BrowserChain.transfer!(@fleet, key, buyer.wallet)
    roster = line("transfer: the notebook hub job ran after the Key moved", roster())
    reason = key_lost_reason()

    moved = [
      line(
        "transfer: old holder's agent's open notebook connection closes (1008 #{inspect(reason)})",
        closes(socket, reason)
      ),
      refusal(
        "transfer: old holder's agent refused in rooms",
        room(c, holder, @fleet),
        403,
        "not_a_member"
      ),
      refusal(
        "transfer: old holder's agent refused the workspace",
        workspace(c, holder, @fleet),
        403,
        "workspace_members_only"
      ),
      refusal(
        "transfer: old holder's agent refused the notebooks",
        notebooks(c, holder, @fleet),
        403,
        "notebooks_not_holder"
      ),
      git_refusal(
        "transfer: git refuses the old holder's agent",
        agent_git(c, holder, @fleet),
        403,
        "code_not_holder"
      ),
      refusal(
        "transfer: old holder's notebook sign-in from before refused",
        notebook_page(c, cookie),
        403,
        "notebooks_not_holder"
      ),
      git_refusal(
        "transfer: git refuses the old holder's own password from before",
        git(c, @fleet, own_password),
        403,
        "code_not_holder"
      ),
      line(
        "transfer: Keyfleet.Access no longer counts the old holder a member",
        member(holder, false)
      ),
      line("transfer: Keyfleet.Access counts the new holder a member", member(buyer, true)),
      admission("transfer: new holder's agent reads a members-only room", room(c, buyer, @fleet)),
      admission("transfer: new holder's agent reads the workspace", workspace(c, buyer, @fleet)),
      admission(
        "transfer: new holder's agent is let into the notebooks",
        notebooks(c, buyer, @fleet)
      ),
      line(
        "transfer: new holder's agent opens a notebook connection",
        opened(open_socket(c, buyer, @fleet))
      ),
      admission("transfer: git lets the new holder's agent in", agent_git(c, buyer, @fleet))
    ]

    before ++ [roster] ++ moved
  end

  defp revocation(c) do
    read_chain!()
    paired = pair!()
    BrowserChain.sell!(@fleet, paired.wallet)
    socket = open_socket(c, paired, @fleet)

    admitted = [
      admission("revocation: paired agent reads a members-only room", room(c, paired, @fleet)),
      admission("revocation: paired agent reads the workspace", workspace(c, paired, @fleet)),
      admission(
        "revocation: paired agent is let into the notebooks",
        notebooks(c, paired, @fleet)
      ),
      line("revocation: paired agent opens a notebook connection", opened(socket)),
      admission("revocation: git lets the paired agent in", agent_git(c, paired, @fleet))
    ]

    unpair!(paired)
    reason = unpaired_reason(paired)

    closed =
      line(
        "revocation: the agent's open notebook connection closes by itself (1008 #{inspect(reason)})",
        closes(socket, reason)
      )

    refused =
      for {place, answer, refused} <- [
            {"in rooms", room(c, paired, @fleet), &refused_exactly/3},
            {"the workspace", workspace(c, paired, @fleet), &refused_exactly/3},
            {"the notebooks", notebooks(c, paired, @fleet), &refused_exactly/3},
            {"the fleet's code", agent_git(c, paired, @fleet), &refused_to_git/3}
          ] do
        line(
          "revocation: unpaired agent refused #{place} (403 agent_not_paired, Refusal's words)",
          refused.(answer, 403, "agent_not_paired")
        )
      end

    site = line("revocation: agent_not_paired sends the person to this site", own_site())
    admitted ++ [closed | refused] ++ [site]
  end

  defp other_fleet(c) do
    read_chain!()
    outsider = pair!()
    BrowserChain.sell!(@other_fleet, outsider.wallet)

    [
      refusal(
        "other fleet: agent refused a members-only room",
        room(c, outsider, @fleet),
        403,
        "not_a_member"
      ),
      line(
        "other fleet: agent is listed general alone",
        general_alone(rooms(c, outsider, @fleet))
      ),
      refusal(
        "other fleet: agent refused the workspace",
        workspace(c, outsider, @fleet),
        403,
        "workspace_members_only"
      ),
      refusal(
        "other fleet: agent refused the notebooks",
        notebooks(c, outsider, @fleet),
        403,
        "notebooks_not_holder"
      ),
      git_refusal(
        "other fleet: git refuses the agent on this fleet's code",
        agent_git(c, outsider, @fleet),
        403,
        "code_not_holder"
      ),
      admission(
        "other fleet: agent reads a members-only room of its own fleet",
        room(c, outsider, @other_fleet)
      ),
      admission(
        "other fleet: agent reads its own fleet's workspace",
        workspace(c, outsider, @other_fleet)
      ),
      admission(
        "other fleet: agent is let into its own fleet's notebooks",
        notebooks(c, outsider, @other_fleet)
      ),
      admission(
        "other fleet: git lets the agent into its own fleet's code",
        agent_git(c, outsider, @other_fleet)
      )
    ]
  end

  ## What is checked

  defp line(label, :ok) do
    IO.puts("pass  " <> label)
    :pass
  end

  defp line(label, {:fail, reason}) do
    IO.puts("fail  " <> label <> ": " <> reason)
    :fail
  end

  defp admission(label, answer), do: line(label, admitted(answer))

  defp refusal(label, answer, status, code),
    do: line("#{label} (#{status} #{code})", refused(answer, status, code))

  defp git_refusal(label, answer, status, code),
    do: line("#{label} (#{status} #{code})", refused_to_git(answer, status, code))

  defp admitted(%{status: status}) when status in 200..299, do: :ok
  defp admitted(answer), do: {:fail, said(answer)}

  defp refused(%{status: status, body: %{"error" => %{"code" => code}}}, status, code), do: :ok
  defp refused(answer, _status, _code), do: {:fail, said(answer)}

  # Git shows the person running it the refusal's message and hint, as text.
  defp refused_to_git(%{status: status, body: body} = answer, status, code) do
    %{error: %{message: message, hint: hint}} = Refusal.body(code)
    if body == message <> "\n" <> hint <> "\n", do: :ok, else: {:fail, said(answer)}
  end

  defp refused_to_git(answer, _status, _code), do: {:fail, said(answer)}

  defp refused_exactly(answer, status, code) do
    %{error: %{message: message, hint: hint}} = Refusal.body(code)

    case answer do
      %{
        status: ^status,
        body: %{"error" => %{"code" => ^code, "message" => ^message, "hint" => ^hint}}
      } ->
        :ok

      %{status: ^status, body: %{"error" => %{"code" => ^code}}} ->
        {:fail, "answered #{status} #{code} in other words than KeyfleetWeb.Refusal's"}

      answer ->
        {:fail, said(answer)}
    end
  end

  # Pairing guidance names this site's Agents page, never regents.sh.
  defp own_site do
    %{error: %{message: message, hint: hint}} = Refusal.body("agent_not_paired")

    if String.contains?(message <> " " <> hint, "regents.sh"),
      do: {:fail, "it says: #{message} #{hint}"},
      else: :ok
  end

  # The one table the pages ask, for the members-only rooms and the workspace.
  defp member(%{person: person}, expected) do
    standing =
      for component <- [:rooms, :workspace],
          do: {component, Keyfleet.Access.allowed?(person, :read, component, @fleet)}

    if Enum.all?(standing, fn {_component, allowed} -> allowed == expected end),
      do: :ok,
      else: {:fail, "Keyfleet.Access answers #{inspect(standing)}"}
  end

  defp general_alone(%{status: 200, body: %{"rooms" => rooms}}) do
    case Enum.map(rooms, & &1["slug"]) do
      ["general"] -> :ok
      slugs -> {:fail, "listed #{Enum.join(slugs, ", ")}"}
    end
  end

  defp general_alone(answer), do: {:fail, said(answer)}

  defp opened({:ok, _socket}), do: :ok
  defp opened({:error, reason}), do: {:fail, reason}

  defp closes({:error, reason}, _reason), do: {:fail, "it never opened: " <> reason}

  defp closes({:ok, socket}, reason) do
    case closing(socket, System.monotonic_time(:millisecond) + @close_within_ms) do
      {:closed, 1008, ^reason} -> :ok
      {:closed, code, other} -> {:fail, "closed with #{code} #{inspect(other)}"}
      {:dropped, why} -> {:fail, "dropped without a close frame: " <> why}
      :open -> {:fail, "still open after #{div(@close_within_ms, 1000)} s"}
    end
  end

  defp said(%{status: nil, body: reason}), do: reason

  defp said(%{status: status, body: %{"error" => %{"code" => code}}}),
    do: "answered #{status} #{code}"

  defp said(%{status: status, body: body}) when is_binary(body) and body != "",
    do: "answered #{status}: " <> hd(String.split(body, "\n"))

  defp said(%{status: status}), do: "answered #{status}"

  # The words an open notebook connection closes with, as the connection
  # gives them: once its holder's Key has gone, and once an agent's pairing
  # has ended.
  defp key_lost_reason do
    {:stop, :normal, {1008, reason}, _state} =
      NotebookSocket.handle_info(:notebook_access_ended, %{})

    reason
  end

  defp unpaired_reason(%{actor: agent}) do
    case NotebookSocket.handle_info(:agents_changed, %{holder: {:agent, agent}, fleet_id: @fleet}) do
      {:stop, :normal, {1008, reason}, _state} -> reason
      _still_open -> nil
    end
  end

  ## The site

  defp start_site! do
    unless Mix.env() == :test,
      do:
        Mix.raise(
          "Run it under the test configuration: MIX_ENV=test MIX_TEST_PARTITION=_membership"
        )

    Mix.Task.run("app.config")
    database = Keyfleet.Repo.config()[:database]

    unless String.ends_with?(database, "_membership_test"),
      do:
        Mix.raise(
          "It empties its database first, so it runs only on keyfleet_membership_test " <>
            "(MIX_TEST_PARTITION=_membership), not #{database}"
        )

    Mix.Task.run("ecto.drop", ["--force", "--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])

    {:ok, _prepared, _apps} =
      Ecto.Migrator.with_repo(Keyfleet.Repo, fn _repo ->
        LocalDatabaseFixture.ensure_human_accounts!()
      end)

    certificate!()
    # Each process holds its connection until it exits under the test pool, and
    # every open notebook connection is one.
    put_config(Keyfleet.Repo, pool_size: 20)
    put_config(KeyfleetWeb.Endpoint, server: true)
    Mix.Task.run("app.start")
  end

  # The certificate the browser test server answers with, made the same way
  # (playwright.config.ts) when there is none yet.
  defp certificate! do
    https = Application.fetch_env!(:keyfleet, KeyfleetWeb.Endpoint)[:https]

    unless File.exists?(https[:certfile]) do
      File.mkdir_p!(Path.dirname(https[:certfile]))

      {_made, 0} =
        System.cmd(
          "openssl",
          ~w(req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost) ++
            ["-addext", "subjectAltName=DNS:localhost"] ++
            ["-keyout", https[:keyfile], "-out", https[:certfile]],
          stderr_to_stdout: true
        )
    end
  end

  defp put_config(key, settings) do
    config = Application.fetch_env!(:keyfleet, key)
    Application.put_env(:keyfleet, key, Keyword.merge(config, settings))
  end

  # The stand-ins the site reaches, each on a free local port.
  defp serve! do
    secret = :crypto.strong_rand_bytes(32)
    Application.put_env(:keyfleet, :siwa_broker_url, local(&sign_in_server(&1, secret)))
    put_config(:notebooks, fleets: %{@fleet => hub!(), @other_fleet => hub!()})
    put_config(:code, node: local(&store/1))
    %{port: KeyfleetWeb.Endpoint.config(:https)[:port], secret: secret}
  end

  defp furnish! do
    BrowserChain.prepare!(@fleet)
    BrowserChain.prepare!(@other_fleet)
    Rooms.bootstrap_rooms!([@fleet, @other_fleet])

    for fleet_id <- [@fleet, @other_fleet] do
      WorkspaceFixtures.open_log(fleet_id)

      general = Projects.project!(fleet_id, Projects.general(), actor: %Actors.System{})
      Projects.record_space!(general, "proj-" <> fleet_id, actor: %Actors.System{})
      Code.record_repository!(general.repository, @store_owner, actor: %Actors.System{})
    end
  end

  defp read_chain! do
    BrowserChain.prepare!(@fleet)
    BrowserChain.prepare!(@other_fleet)

    case roster() do
      :ok -> :ok
      {:fail, reason} -> Mix.raise("The notebook hub job failed: " <> reason)
    end
  end

  # The job that brings each fleet's hub in step with who holds its Keys, as
  # Oban runs it on Base after a Key moves. What it ends reaches the gateways'
  # admissions before the next request.
  defp roster do
    ran = Oban.drain_queue(queue: :notebook_hubs)
    :sys.get_state(Keyfleet.AccessCache)

    if match?(%{failure: 0, discard: 0, snoozed: 0, cancelled: 0}, ran),
      do: :ok,
      else: {:fail, "it ended #{inspect(ran)}"}
  end

  ## People and their agents

  # A person with a fresh wallet, and their agent, paired the way the person's
  # Agents page pairs one, with a profile so it may open the notebooks.
  defp pair! do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    {:ok, signer} = Siwa.LocalSigner.new()

    agent =
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: signer.address,
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [wallet]
      )

    Keyfleet.Agents.ensure_profile!(%{name: "Membership check", declared_harness: "test"},
      actor: agent
    )

    %{wallet: wallet, person: agent.pairing, signer: signer, actor: agent}
  end

  defp unpair!(%{actor: agent}) do
    person = %RegentAgents.Person{privy_user_id: agent.privy_user_id}
    {:ok, pairing} = RegentAgents.get_my_agent(agent.pairing_id, actor: person)
    :ok = RegentAgents.unpair_agent(pairing, actor: person)
  end

  ## Requests

  defp room(c, agent, fleet_id),
    do:
      signed(
        c,
        agent,
        "POST",
        "/api/v1/agent/fleets/#{fleet_id}/rooms/business/messages/read",
        "{}"
      )

  defp rooms(c, agent, fleet_id),
    do: signed(c, agent, "GET", "/api/v1/agent/fleets/#{fleet_id}/rooms", nil)

  defp workspace(c, agent, fleet_id),
    do: signed(c, agent, "POST", "/api/v1/agent/fleets/#{fleet_id}/graph/changes", "{}")

  # Git as an agent runs it through the signing helper: every request to the
  # code host signed with the agent's own key, an empty body included.
  defp agent_git(c, agent, fleet_id) do
    path = "/#{fleet_id}.git/info/refs?service=git-upload-pack"
    headers = signed_headers(c, agent, "GET", path, "")
    send_request(c, "GET", Code.config()[:host], path, headers, nil)
  end

  # On the notebook host a GET signs the empty body too.
  defp notebooks(c, agent, fleet_id) do
    headers = signed_headers(c, agent, "GET", "/", "")
    send_request(c, "GET", Notebooks.host(fleet_id), "/", headers, nil)
  end

  defp signed(c, agent, method, path, body) do
    headers = signed_headers(c, agent, method, path, body)
    send_request(c, method, "localhost", path, headers, body)
  end

  defp git(_c, _fleet_id, nil), do: %{status: nil, body: "no password to give git"}

  defp git(c, fleet_id, password) do
    send_request(
      c,
      "GET",
      Code.config()[:host],
      "/#{fleet_id}.git/info/refs?service=git-upload-pack",
      [{"authorization", Plug.BasicAuth.encode_basic_auth("git", password)}],
      nil
    )
  end

  # A fresh Keyfleet sign-in for the person, by its lineage.
  defp signed_in!(%{person: person}),
    do: SessionAuthorityHelpers.signed_in_session(person.human_account_id)["session_lineage"]

  # A notebook sign-in for the person, made the way the fleet's workspace
  # makes one: a code that works once, sent to the notebook host from this
  # site's page for its cookie.
  defp notebook_cookie(c, %{person: person}, lineage) do
    with {:ok, entry} <- Notebooks.open(person, lineage, @fleet),
         headers = [
           {"origin", KeyfleetWeb.Endpoint.url()},
           {"content-type", "application/x-www-form-urlencoded"}
         ],
         form = URI.encode_query(code: entry.code, to: entry.to),
         %{status: 303, headers: %{"set-cookie" => set}} <-
           send_request(
             c,
             "POST",
             Notebooks.host(@fleet),
             URI.parse(entry.action).path,
             headers,
             form
           ) do
      Enum.find_value(set, &notebook_cookie_value/1)
    else
      _refused -> nil
    end
  end

  defp notebook_cookie_value(set_cookie) do
    case String.split(hd(String.split(set_cookie, ";")), "=", parts: 2) do
      [@cookie, value] -> value
      _other -> nil
    end
  end

  # The password the person's own sign-in gives git for the fleet's code.
  defp person_password(%{person: person}, lineage) do
    case CodePassword.for_person(person, lineage, @fleet) do
      {:ok, %{password: password}} -> password
      {:error, _refused} -> nil
    end
  end

  defp notebook_page(_c, nil), do: %{status: nil, body: "no notebook sign-in was handed out"}

  defp notebook_page(c, cookie) do
    headers = [{"cookie", "#{@cookie}=#{cookie}"}]
    send_request(c, "GET", Notebooks.host(@fleet), "/", headers, nil)
  end

  # Signed as the docs say an agent signs ("Sign-in"), under a
  # fresh receipt from the stand-in sign-in server's secret.
  defp signed_headers(c, agent, method, path, body) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => agent.signer.address,
          "chain_id" => 8453,
          "aud" => "keyfleet",
          "key_id" => agent.signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: c.secret
      )

    {:ok, %{headers: headers}} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{
          method: method,
          path: path,
          body: body,
          headers: %{"content-type" => "application/json"}
        },
        receipt,
        agent.signer,
        secret: c.secret,
        audience: "keyfleet",
        wallet_audiences: ["keyfleet"]
      )

    headers
  end

  # The certificate is the one the site made for itself.
  defp send_request(c, method, host, path, headers, body) do
    case Req.request(
           method: method |> String.downcase() |> String.to_existing_atom(),
           url: "https://localhost:#{c.port}" <> path,
           headers: [{"host", host} | Enum.to_list(headers)],
           body: body,
           connect_options: [transport_opts: [verify: :verify_none]],
           retry: false,
           redirect: false
         ) do
      {:ok, response} -> response
      {:error, error} -> %{status: nil, body: "no answer: " <> Exception.message(error)}
    end
  end

  ## Notebook connections

  # A live notebook connection the agent opens through the gateway, signed as
  # every request to the notebook host is.
  defp open_socket(c, agent, fleet_id) do
    path = "/api/v1/events"
    headers = signed_headers(c, agent, "GET", path, "")

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, "localhost", c.port,
             protocols: [:http1],
             transport_opts: [verify: :verify_none]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, path, [
             {"host", Notebooks.host(fleet_id)} | Enum.to_list(headers)
           ]),
         {:ok, conn, 101, response_headers, _body} <- upgraded(conn, ref, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, 101, response_headers) do
      {:ok, %{conn: conn, ref: ref, websocket: websocket}}
    else
      {:ok, _conn, status, _headers, body} ->
        {:error, said(%{status: status, body: decoded(body)})}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, error} ->
        {:error, Exception.message(error)}

      {:error, _conn, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp upgraded(conn, ref, parts) do
    with {:ok, message} <- next_message(conn, @answer_within_ms),
         {:ok, conn, more} <- Mint.WebSocket.stream(conn, message) do
      parts = parts ++ more

      if Enum.any?(parts, &match?({:done, ^ref}, &1)),
        do: upgrade_answer(conn, ref, parts),
        else: upgraded(conn, ref, parts)
    else
      :timeout -> {:error, "no answer to the upgrade in #{div(@answer_within_ms, 1000)} s"}
      {:error, _conn, error, _parts} -> {:error, Exception.message(error)}
    end
  end

  defp upgrade_answer(conn, ref, parts) do
    {:status, ^ref, status} = List.keyfind(parts, :status, 0)
    {:headers, ^ref, headers} = List.keyfind(parts, :headers, 0)
    {:ok, conn, status, headers, IO.iodata_to_binary(for {:data, ^ref, data} <- parts, do: data)}
  end

  # What the site does with the open connection by `deadline`: closes it, as
  # `{:closed, code, reason}`, drops it without a close frame, or leaves it
  # open.
  defp closing(%{conn: conn, ref: ref, websocket: websocket} = socket, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:ok, message} <- next_message(conn, left),
         {:ok, conn, parts} <- Mint.WebSocket.stream(conn, message),
         {:ok, websocket, frames} <-
           Mint.WebSocket.decode(
             websocket,
             IO.iodata_to_binary(for {:data, ^ref, data} <- parts, do: data)
           ) do
      case List.keyfind(frames, :close, 0) do
        {:close, code, reason} -> {:closed, code, reason}
        nil -> closing(%{socket | conn: conn, websocket: websocket}, deadline)
      end
    else
      :timeout -> :open
      {:error, _conn, error, _parts} -> {:dropped, Exception.message(error)}
      {:error, _websocket, reason} -> {:dropped, inspect(reason)}
    end
  end

  # The next thing the connection's socket sends this process.
  defp next_message(conn, timeout) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {:ssl, ^socket, _data} = message -> {:ok, message}
      {:ssl_closed, ^socket} = message -> {:ok, message}
      {:ssl_error, ^socket, _reason} = message -> {:ok, message}
    after
      timeout -> :timeout
    end
  end

  defp decoded(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _not_json} -> body
    end
  end

  ## The stand-ins

  defp local(answer) do
    {:ok, pid} =
      Bandit.start_link(
        plug: fn conn, _opts -> answer.(conn) end,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  # The sign-in server: it checks each signed request the way the real one
  # does, and answers with the agent's wallet.
  defp sign_in_server(conn, secret) do
    {:ok, raw, conn} = read_body(conn)
    payload = Jason.decode!(raw)

    case Siwa.verify_authenticated_request(SignedAgentHelpers.siwa_request(payload),
           secret: secret,
           audience: "keyfleet",
           wallet_audiences: ["keyfleet"]
         ) do
      {:ok, %{claims: claims, covered_components: covered}} ->
        json(conn, 200, %{
          code: "http_envelope_valid",
          data: %{
            verified: true,
            walletAddress: claims["sub"],
            chainId: claims["chain_id"],
            verificationMethod: "eoa_recovery",
            keyId: claims["key_id"],
            receiptExpiresAt:
              claims["exp"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
            requiredHeaders: Siwa.required_authenticated_request_headers(payload["body_digest"]),
            requiredCoveredComponents:
              Siwa.required_authenticated_request_components(
                payload["headers"],
                payload["body_digest"]
              ),
            coveredComponents: covered,
            agentRegistration: nil,
            agentBook: nil,
            principal: %{
              kind: "wallet",
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              audience: claims["aud"]
            }
          }
        })

      {:error, _reason} ->
        json(conn, 401, %{
          error: %{
            code: "http_signature_invalid",
            message: "The request signature did not verify.",
            hint: "Sign the request again with your agent key, then send it."
          }
        })
    end
  end

  # A fleet's notebook hub: it keeps who this site made an editor of the
  # fleet's project, answers every other request 200 and keeps every live
  # connection open.
  defp hub! do
    {:ok, people} = Agent.start_link(fn -> %{members: MapSet.new(), users: MapSet.new()} end)
    local(&hub(&1, people))
  end

  defp hub(%Plug.Conn{method: "GET", path_info: ["api", "v1", "admin", "users"]} = conn, people) do
    users = for subject <- Agent.get(people, & &1.users), do: %{id: subject, suspended_at: nil}
    hub_answer(conn, 200, %{items: users, next_cursor: nil})
  end

  defp hub(
         %Plug.Conn{method: "GET", path_info: ["api", "v1", "projects", _project, "members"]} =
           conn,
         people
       ) do
    members =
      for subject <- Agent.get(people, & &1.members), do: %{email: Notebooks.email(subject)}

    hub_answer(conn, 200, members)
  end

  defp hub(
         %Plug.Conn{method: "POST", path_info: ["api", "v1", "projects", _project, "members"]} =
           conn,
         people
       ) do
    {:ok, body, conn} = read_body(conn)
    subject = body |> Jason.decode!() |> Map.fetch!("email") |> Notebooks.subject_of_email()

    Agent.update(people, fn kept ->
      %{members: MapSet.put(kept.members, subject), users: MapSet.put(kept.users, subject)}
    end)

    hub_answer(conn, 201, %{})
  end

  defp hub(
         %Plug.Conn{
           method: "DELETE",
           path_info: ["api", "v1", "projects", _project, "members", member]
         } = conn,
         people
       ) do
    member = URI.decode(member)
    subject = Notebooks.subject_of_email(member) || member
    Agent.update(people, &%{&1 | members: MapSet.delete(&1.members, subject)})
    hub_answer(conn, 200, %{})
  end

  defp hub(conn, _people) do
    if get_req_header(conn, "upgrade") == ["websocket"],
      do: WebSockAdapter.upgrade(conn, HubSocket, nil, timeout: :infinity),
      else: hub_answer(conn, 200, %{})
  end

  defp hub_answer(conn, status, data), do: json(conn, status, %{success: true, data: data})

  # The code store: whatever git asks for what a repository holds, an empty one.
  defp store(conn) do
    service = fetch_query_params(conn).query_params["service"]
    line = "# service=#{service}\n"
    length = String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0")

    conn
    |> put_resp_content_type("application/x-#{service}-advertisement", nil)
    |> send_resp(200, String.downcase(length) <> line <> "0000")
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
