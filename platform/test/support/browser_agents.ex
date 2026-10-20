defmodule Keyfleet.BrowserAgents do
  @moduledoc """
  The browser tests' agents. Called on the browser test server's own node, it
  makes agents with signers of their own, signs the requests a page's
  `prepare_agent_request` tool prepares for them, as an agent's own SIWA
  signer does, and pairs them with people, so a spec drives a page's signed
  tools the way an agent does.

  The server checks each signed request with a stand-in for the SIWA sign-in
  server that `start!/0` starts. It verifies the real signature under the
  real receipt (`KeyfleetWeb.SignedAgentHelpers.verdict/2`), for Keyfleet's
  own agent routes (`:siwa_broker_url`) and for the ones every Regent site
  shares (`RegentAgents.Broker`, whose requests `Req.Test` hands it).
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Capabilities
  alias Keyfleet.PairingHelpers
  alias KeyfleetWeb.SignedAgentHelpers

  @doc """
  Starts the stand-in sign-in server on a free loopback port, in a process of
  its own that lives as long as the node does, and points both kinds of
  agent route at it.
  """
  def start! do
    caller = self()

    spawn(fn ->
      secret = :crypto.strong_rand_bytes(32)
      :persistent_term.put({__MODULE__, :secret}, secret)
      plug = fn conn, _opts -> verify(conn, secret) end

      {:ok, server} =
        Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      Application.put_env(:keyfleet, :siwa_broker_url, "http://127.0.0.1:#{port}")

      # Every process on the server reaches the stub this process owns.
      Req.Test.set_req_test_to_shared()
      Req.Test.stub(RegentAgents.Broker, plug)
      send(caller, :started)
      Process.sleep(:infinity)
    end)

    receive do
      :started -> :ok
    end
  end

  @doc "Makes an agent with a signer of its own; returns its wallet."
  def new_agent! do
    {:ok, signer} = Siwa.LocalSigner.new()
    :persistent_term.put({__MODULE__, signer.address}, signer)
    signer.address
  end

  @doc """
  The proof `agent`'s signer makes for a request a page prepared, given as its
  `method`, `path` and, for any request but a read, `body`: exactly the
  headers the tool manifest lists, as JSON.
  """
  def sign!(agent, %{"method" => method, "path" => path} = request) do
    %{headers: headers} =
      SignedAgentHelpers.sign(
        :persistent_term.get({__MODULE__, agent}),
        :persistent_term.get({__MODULE__, :secret}),
        method,
        path,
        request["body"]
      )

    headers |> Map.take(Capabilities.manifest()["proof_headers"]) |> Jason.encode!()
  end

  @doc "Pairs `agent`, called `name`, with the person signed in to Privy as `person`."
  def pair_person!(agent, person, name) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person})

    RegentAgents.pair_agent!(code, name, :hermes, actor: %RegentAgents.Agent{wallet: agent})
    :ok
  end

  @doc "Pairs `agent` with the person whose wallet is `person`, making their account first."
  def pair!(agent, person) do
    PairingHelpers.pair!(
      %Agent{
        wallet_address: agent,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      },
      [person]
    )

    :ok
  end

  defp verify(conn, secret) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {status, body} = SignedAgentHelpers.verdict(Jason.decode!(raw), secret)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
