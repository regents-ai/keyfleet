defmodule Keyfleet.BrowserAgents do
  @moduledoc """
  The browser tests' agents. Called on the browser test server's own node, it
  makes agents with signers of their own, signs the exact request a page's
  signed tool builds for them, as an agent's browser host does with its own
  SIWA key, and pairs them with people, so a spec drives a page's signed
  tools the way an agent does.

  The server checks each signed request with a stand-in for the SIWA sign-in
  server that `start!/0` starts. It verifies the real signature under the
  real receipt (`KeyfleetWeb.SignedAgentHelpers.verdict/2`), for Keyfleet's
  own agent routes (`:siwa_broker_url`) and for the ones every Regent site
  shares (`RegentAgents.Broker`, whose requests `Req.Test` hands it).
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
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
  The proof `agent`'s signer makes for a request a page built, given as the
  `origin` it goes to, its `method`, `path` and, for any request but a read,
  `body`: exactly the headers the tool manifest lists, as JSON.
  """
  def sign!(agent, %{"origin" => origin, "method" => method, "path" => path} = request) do
    %{headers: headers} =
      SignedAgentHelpers.sign(
        :persistent_term.get({__MODULE__, agent}),
        :persistent_term.get({__MODULE__, :secret}),
        Siwa.Contract.authority(origin),
        method,
        path,
        request["body"]
      )

    headers |> Map.take(Capabilities.manifest()["proof_headers"]) |> Jason.encode!()
  end

  @doc """
  A pairing code from the person whose wallet is `person`, as Pair New Agent
  shows one, making their account first.
  """
  def pairing_code!(person) do
    subject = "did:privy:test-" <> person

    Keyfleet.Accounts.register_verified!(subject, person, [person],
      actor: %Keyfleet.Actors.System{}
    )

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: subject})

    code
  end

  @doc """
  Pairs `agent`, called `name`, on `harness` (a `RegentAgents.Harness` value),
  with the person signed in to Privy as `person`.
  """
  def pair_person!(agent, person, name, harness) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person})

    RegentAgents.pair_agent!(code, name, harness, actor: %RegentAgents.Agent{wallet: agent})
    :ok
  end

  @doc """
  Pairs `agent`, called `name`, with the `code` a pairing box shows, and tells
  the person's open pages, as `RegentAgents.Listener` does once the pairing
  commits; the walk's one held transaction never commits, so the database's
  notice never comes.
  """
  def use_code!(agent, code, name) do
    paired =
      RegentAgents.pair_agent!(code, name, :hermes, actor: %RegentAgents.Agent{wallet: agent})

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      RegentAgents.topic(paired.privy_user_id),
      :agents_changed
    )
  end

  @doc """
  `agent`'s daily run checks in with the fleet, as a sync from its scheduled
  run does, with a profile of its own made the first time. Like a real
  check-in, it tells the open pages of the agent's person.
  """
  def check_in!(agent, fleet_id) do
    {:ok, actor} = Agents.with_pairing(agent_actor(agent))
    Agents.ensure_profile!(%{name: "Browser agent", declared_harness: "test"}, actor: actor)

    {:ok, _check_ins} =
      Agents.check_in(actor, fleet_id, %{"kind" => "scheduled", "every_minutes" => 1440})

    :ok
  end

  @doc "Pairs `agent` with the person whose wallet is `person`, making their account first."
  def pair!(agent, person) do
    PairingHelpers.pair!(agent_actor(agent), [person])
    :ok
  end

  # `agent` signed in on Base, where the Keys are.
  defp agent_actor(agent),
    do: %Agent{
      wallet_address: agent,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

  defp verify(conn, secret) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {status, body} = SignedAgentHelpers.verdict(Jason.decode!(raw), secret)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
