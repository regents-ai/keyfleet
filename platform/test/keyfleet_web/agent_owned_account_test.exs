defmodule KeyfleetWeb.AgentOwnedAccountTest do
  # An agent opens its own account with a signed request, and from then on its
  # signed requests act for that account as its owner, with no person to pair
  # with (agent parity K1, ash-template's G1). Privy is a stand-in that knows the
  # users this test gives it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.{Accounts, Agents, PairingHelpers}
  alias Keyfleet.Accounts.{AgentAccount, RequestRateLimiter, VerifiedSession}
  alias Keyfleet.Actors.{Agent, Human, System}
  alias KeyfleetWeb.AgentTools.Account.Answer
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @open "/api/v1/agent/account"
  @did "did:privy:keyfleet-agent-own"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    {:ok, signer} = Siwa.LocalSigner.new()
    %{secret: secret, signer: signer, wallet: String.downcase(signer.address)}
  end

  test "an agent opens its own account, then acts for it as its owner", c do
    privy(c, :none)

    opened = c |> post!(@open, %{}) |> json_response(200)

    assert %{
             "account" => %{
               "wallet_address" => wallet,
               "wallet_addresses" => [wallet],
               "display_name" => nil
             }
           } = opened

    assert wallet == c.wallet
    # Privy was asked for the wallet's user, then made one marked for the agent.
    assert_received {:privy, "/v1/users/wallet/address", %{"address" => ^wallet}}

    assert_received {:privy, "/v1/users",
                     %{
                       "linked_accounts" => [%{"type" => "wallet", "address" => ^wallet}],
                       "custom_metadata" => %{"regent_agent" => ^wallet}
                     }}

    {:ok, account} = Accounts.get_by_privy_did(@did, actor: %System{})
    assert account.wallet_address == wallet

    # A request that needs an account now acts for this one, under no grant.
    balances = c |> get!("/api/v1/agent/account/balances") |> json_response(200)
    assert %{"spending_grant" => nil, "credits" => _credits} = balances

    {:ok, actor} = Agents.with_pairing(agent(wallet))
    assert %Agent{owner?: true, pairing_id: nil, privy_user_id: @did} = actor
    assert %Human{human_account_id: id, wallet_addresses: [^wallet | _]} = actor.pairing
    assert id == account.id

    # Its own profile is kept as any agent's, rechecked against the account.
    joined =
      c |> post!("/api/v1/agent/join/status", %{"name" => "Sol", "declared_harness" => "codex"})

    assert %{"profile" => %{"name" => "Sol"}} = json_response(joined, 200)

    # Its picture's upload address carries the owner, who may still use it.
    declared = %{
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 100,
      "content_type" => "image/png"
    }

    {200, %{upload_url: url}, nil} = Answer.answer(:avatar_start, declared, actor, nil)
    ticket = url |> String.split("/") |> List.last()
    assert {:ok, %{actor: %Agent{owner?: true}}} = Answer.upload(ticket, "image/png")

    # Opening again answers the same account and asks Privy nothing.
    assert c |> post!(@open, %{}) |> json_response(200) == opened
    refute_received {:privy, _path, _body}
  end

  test "an agent's own Privy user opened on another Regent site is taken", c do
    privy(c, :agent)

    assert %{"account" => %{"wallet_address" => wallet}} =
             c |> post!(@open, %{}) |> json_response(200)

    assert wallet == c.wallet
    refute_received {:privy, "/v1/users", _body}
  end

  test "an account the agent opened elsewhere that now signs in with another wallet is left as it is",
       c do
    privy(c, :agent)
    other = "0x" <> String.duplicate("7", 40)
    {:ok, account} = VerifiedSession.register(@did, other, [other, c.wallet])

    refused = c |> post!(@open, %{}) |> json_response(409)
    assert refused["error"]["code"] == "account_not_opened"
    assert {:ok, nil} = AgentAccount.owned(c.wallet)

    assert {:ok, %{wallet_address: ^other, wallet_addresses: [^other, _agent]}} =
             Accounts.get_by_privy_did(@did, actor: %System{})

    assert account.wallet_address == other
  end

  test "whoami names the owner and its account", c do
    privy(c, :none)
    {:ok, _account} = AgentAccount.open(c.wallet)
    wallet = c.wallet

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      Req.Test.json(conn, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "agentRegistration" => nil,
          "agentBook" => nil,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => wallet,
            "chain_id" => 8453,
            "audience" => "keyfleet"
          }
        }
      })
    end)

    data =
      build_conn() |> get("/api/agents/v1/whoami") |> json_response(200) |> Map.fetch!("data")

    assert data["status"] == "owner"
    assert data["allowed"] == Application.fetch_env!(:regent_agents, :allowed)["owner"]
    assert %{"wallet_address" => ^wallet} = data["account"]
  end

  test "a wallet that signs in to a person's account opens nothing", c do
    privy(c, :person)

    refused = c |> post!(@open, %{}) |> json_response(409)
    assert refused["error"]["code"] == "wallet_in_use"
    assert {:ok, nil} = AgentAccount.owned(c.wallet)
    assert {:ok, nil} = Accounts.get_by_privy_did(@did, actor: %System{})
  end

  test "an agent a person paired opens nothing", c do
    PairingHelpers.pair_wallet!(c.wallet)

    refused = c |> post!(@open, %{}) |> json_response(409)
    assert refused["error"]["code"] == "agent_paired"
    refute_received {:privy, _path, _body}
  end

  test "opening takes an empty object", c do
    refused = c |> post!(@open, %{"name" => "Sol"}) |> json_response(422)
    assert refused["error"]["code"] == "invalid_request"
    assert refused["error"]["hint"] =~ "an empty JSON object"
  end

  test "Privy refusing or failing opens nothing", c do
    for {status, code, http} <- [
          {400, "account_not_opened", 409},
          {500, "accounts_unavailable", 503}
        ] do
      Req.Test.stub(RegentPrivy.Users, &Plug.Conn.send_resp(&1, status, "{}"))
      assert c |> post!(@open, %{}) |> json_response(http) |> get_in(["error", "code"]) == code
    end

    assert {:ok, nil} = AgentAccount.owned(c.wallet)
  end

  test "an account whose sign-in wallet moved is no longer the agent's", c do
    privy(c, :none)
    {:ok, account} = AgentAccount.open(c.wallet)
    other = "0x" <> String.duplicate("7", 40)

    Accounts.refresh_verified!(account, other, [other], actor: %System{})

    assert {:ok, nil} = AgentAccount.owned(c.wallet)
    assert {:error, :not_paired} = Agents.with_pairing(agent(c.wallet))

    # An owner read before the move acts for the account no more.
    stale = %{agent(c.wallet) | owner?: true, human_account_id: account.id}
    refute Agent.valid?(stale)
    assert {:error, :not_paired} = Agent.refresh(stale)

    assert {:error, _not_owner} =
             Agents.ensure_profile(%{name: "Sol", declared_harness: :codex}, actor: stale)
  end

  test "one network opens five accounts a day", c do
    budget = Application.fetch_env!(:keyfleet, :account_open_rate_limit)
    Application.put_env(:keyfleet, :account_open_rate_limit, limit: 5, window_seconds: 86_400)
    :ets.delete_all_objects(RequestRateLimiter)

    on_exit(fn ->
      Application.put_env(:keyfleet, :account_open_rate_limit, budget)
      :ets.delete_all_objects(RequestRateLimiter)
    end)

    # Each try spends the budget, opened or not.
    Req.Test.stub(RegentPrivy.Users, &Plug.Conn.send_resp(&1, 400, "{}"))
    for _try <- 1..5, do: assert(c |> post!(@open, %{}) |> json_response(409))

    limited = c |> post!(@open, %{})
    assert json_response(limited, 429)["error"]["code"] == "account_openings_limited"
    assert [seconds] = get_resp_header(limited, "retry-after")
    assert String.to_integer(seconds) in 1..86_400
  end

  # Privy as the agent's wallet finds it: linked to no user, to a user an agent
  # opening made for it, or to a person's user. Each request reaches the test.
  defp privy(c, linked) do
    test = self()
    wallet = c.wallet

    Req.Test.stub(RegentPrivy.Users, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:privy, conn.request_path, Jason.decode!(body)})

      case {conn.request_path, linked} do
        {"/v1/users/wallet/address", :none} ->
          Plug.Conn.send_resp(conn, 404, "{}")

        {"/v1/users/wallet/address", :person} ->
          Req.Test.json(conn, %{"id" => @did})

        _agent_or_made ->
          Req.Test.json(conn, %{"id" => @did, "custom_metadata" => %{"regent_agent" => wallet}})
      end
    end)
  end

  defp agent(wallet),
    do: %Agent{
      wallet_address: wallet,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

  defp post!(c, path, body), do: signed(c, "POST", path, Jason.encode!(body))
  defp get!(c, path), do: signed(c, "GET", path, nil)

  defp signed(c, method, path, raw) do
    request = SignedAgentHelpers.sign(c.signer, c.secret, method, path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 153}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, String.downcase(method) |> String.to_atom(), path, raw)
  end
end
