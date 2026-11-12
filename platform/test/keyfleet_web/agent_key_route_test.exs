defmodule KeyfleetWeb.AgentKeyRouteTest do
  # A paired agent reads which of its person's agents are on which of their
  # Keys, through its own signed requests and its tools; a Key holds several,
  # and only the person puts one there, moves it or takes it off.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @read "/api/v1/agent/fleets/#{@fleet}/agent_keys"
  @person "0x00000000000000000000000000000000000000ab"
  @other "0x00000000000000000000000000000000000000cd"
  @second "0x00000000000000000000000000000000000000ef"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    record!(3, @person)
    record!(9, @person)
    record!(4, @other)

    # The signing agent and a second agent of the same person.
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)
    agent = Keyfleet.PairingHelpers.pair_wallet!(wallet, @person)
    pair!(agent.privy_user_id, "Second", @second)

    %{secret: secret, signer: signer, wallet: wallet, person: agent.pairing}
  end

  test "the agent reads where its person put it and their other agent", c do
    read = c |> get!(@read) |> json_response(200)

    assert ContractSchema.response_errors(read, "GET", path(), 200) == []

    assert read["agent_keys"] == %{
             "fleet_id" => @fleet,
             "keys" => [%{"token_id" => 3, "agents" => []}, %{"token_id" => 9, "agents" => []}],
             "agents" => [
               %{"name" => "Test agent", "wallet" => c.wallet},
               %{"name" => "Second", "wallet" => @second}
             ],
             "yours" => nil
           }

    for agent_wallet <- [c.wallet, @second],
        do: assert({:ok, _assigned} = Keys.assign_agent(@fleet, 9, agent_wallet, actor: c.person))

    read = c |> get!(@read) |> json_response(200)

    assert ContractSchema.response_errors(read, "GET", path(), 200) == []
    assert names(read) == [{9, ["Test agent", "Second"]}, {3, []}]
    assert read["agent_keys"]["yours"] == 9

    # The fleet check names the Key it acts as, put there by its person.
    doctor = c |> get!("/api/v1/agent/fleets/#{@fleet}/doctor") |> json_response(200)
    assert %{"token_id" => 9, "for_person" => true, "assigned" => true} = doctor["key"]
  end

  test "the agent's tool reads its person's Keys as its signed request does", c do
    {:ok, agent} = Keyfleet.Agents.with_pairing(agent(c))

    assert {:ok, %{agent_keys: %{yours: nil}}} = tool(:agents, %{fleet_id: @fleet}, agent)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 3, c.wallet, actor: c.person)

    assert {:ok, %{agent_keys: %{yours: 3, keys: [%{token_id: 3, agents: [_on_it]} | _]}}} =
             tool(:agents, %{fleet_id: @fleet}, agent)

    assert %{token_id: 3, for_person: true} = Keys.identity(agent, @fleet)
  end

  test "a fleet that doesn't exist answers fleet_unknown", c do
    answer = get!(c, "/api/v1/agent/fleets/no_such_fleet/agent_keys")
    assert json_response(answer, 404)["error"]["code"] == "fleet_unknown"
  end

  defp tool(action, input, agent) do
    KeyfleetWeb.AgentTools.Keys
    |> Ash.ActionInput.for_action(action, input, actor: agent, context: %{waiter: nil})
    |> Ash.run_action()
  end

  defp agent(c),
    do: %Keyfleet.Actors.Agent{
      wallet_address: c.wallet,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

  defp path, do: "/api/v1/agent/fleets/{fleet_id}/agent_keys"

  # Each Key of the answer, in its order, with the names of the agents on it.
  defp names(%{"agent_keys" => %{"keys" => keys}}),
    do: Enum.map(keys, &{&1["token_id"], Enum.map(&1["agents"], fn agent -> agent["name"] end)})

  defp pair!(privy_user_id, name, wallet) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: privy_user_id})

    RegentAgents.pair_agent!(code, name, :codex, actor: %RegentAgents.Agent{wallet: wallet})
  end

  defp get!(c, path) do
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "GET", path, nil)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 152}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :get, path)
  end

  defp record!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}-agent-keys"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end
end
