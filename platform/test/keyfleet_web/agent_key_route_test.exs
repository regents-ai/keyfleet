defmodule KeyfleetWeb.AgentKeyRouteTest do
  # A paired agent reads which of its person's agents is on which of their
  # Keys, and puts one on a Key or takes it off, through its own signed
  # requests and its tools, as the person's Account page does.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys}
  alias KeyfleetWeb.AgentTools.Keys.Answer
  alias KeyfleetWeb.AgentTools.Refused
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @read "/api/v1/agent/fleets/#{@fleet}/agent_keys"
  @assign "/api/v1/agent/fleets/#{@fleet}/agent_keys/assign"
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

    %{secret: secret, signer: signer, wallet: wallet}
  end

  test "the agent puts itself and its person's other agent on Keys, and reads where each is",
       c do
    read = c |> get!(@read) |> json_response(200)

    assert ContractSchema.response_errors(read, "GET", path(), 200) == []

    assert read["agent_keys"] == %{
             "fleet_id" => @fleet,
             "keys" => [%{"token_id" => 3, "agent" => nil}, %{"token_id" => 9, "agent" => nil}],
             "agents" => [
               %{"name" => "Test agent", "wallet" => c.wallet},
               %{"name" => "Second", "wallet" => @second}
             ],
             "yours" => nil
           }

    put =
      c |> post!(@assign, %{"token_id" => 9, "agent_wallet" => c.wallet}) |> json_response(200)

    assert ContractSchema.response_errors(put, "POST", path("/assign"), 200) == []

    assert put["agent_keys"]["keys"] == [
             %{"token_id" => 9, "agent" => %{"name" => "Test agent", "wallet" => c.wallet}},
             %{"token_id" => 3, "agent" => nil}
           ]

    assert put["agent_keys"]["yours"] == 9

    second = String.upcase(@second) |> String.replace_prefix("0X", "0x")
    put = c |> post!(@assign, %{"token_id" => 3, "agent_wallet" => second}) |> json_response(200)

    assert Enum.map(put["agent_keys"]["keys"], &{&1["token_id"], &1["agent"]["name"]}) == [
             {3, "Second"},
             {9, "Test agent"}
           ]

    # The fleet check names the Key it acts as, put there by its person.
    doctor = c |> get!("/api/v1/agent/fleets/#{@fleet}/doctor") |> json_response(200)
    assert %{"token_id" => 9, "for_person" => true, "assigned" => true} = doctor["key"]

    # No agent named takes the Key's agent off.
    off = c |> post!(@assign, %{"token_id" => 9}) |> json_response(200)
    assert off["agent_keys"]["yours"] == nil
    assert hd(off["agent_keys"]["keys"])["token_id"] == 3
  end

  test "a Key the person doesn't hold, or a wallet no agent of theirs has, is refused", c do
    assert post!(c, @assign, %{"token_id" => 9, "agent_wallet" => c.wallet}).status == 200

    for {body, code} <- [
          {%{"token_id" => 4, "agent_wallet" => c.wallet}, "key_not_held"},
          {%{"token_id" => 999, "agent_wallet" => c.wallet}, "key_not_held"},
          {%{"token_id" => 3, "agent_wallet" => @other}, "agent_unknown"}
        ] do
      refused = c |> post!(@assign, body) |> json_response(409)
      assert refused["error"]["code"] == code, inspect(body)
      assert ContractSchema.response_errors(refused, "POST", path("/assign"), 409) == []
    end

    assert c |> get!(@read) |> json_response(200) |> get_in(["agent_keys", "yours"]) == 9
  end

  test "a body that isn't one Key and maybe one wallet is refused", c do
    for body <- [
          %{},
          %{"token_id" => "nine"},
          %{"token_id" => 0},
          %{"token_id" => 9, "agent_wallet" => "0xab"},
          %{"token_id" => 9, "agent_wallet" => nil},
          %{"token_id" => 9, "wallet" => c.wallet}
        ] do
      assert post!(c, @assign, body).status == 422, inspect(body)
    end
  end

  test "the agent's tools read and put an agent on a Key as its signed requests do", c do
    {:ok, agent} = Keyfleet.Agents.with_pairing(agent(c))

    assert {:ok, %{agent_keys: %{yours: nil}}} = tool(:agents, %{fleet_id: @fleet}, agent)

    assert {:ok, %{agent_keys: %{yours: 3}}} =
             tool(:assign_agent, %{fleet_id: @fleet, token_id: 3, agent_wallet: c.wallet}, agent)

    assert %{token_id: 3, for_person: true} = Keys.identity(agent, @fleet)

    assert {:error, %Ash.Error.Invalid{errors: [%Refused{status: 409} = refused]}} =
             tool(:assign_agent, %{fleet_id: @fleet, token_id: 4}, agent)

    assert refused.body.error.code == "key_not_held"

    assert {:ok, %{agent_keys: %{yours: nil}}} =
             tool(:assign_agent, %{fleet_id: @fleet, token_id: 3}, agent)
  end

  # The tools take a body the signed route has not checked, so each shape it
  # refuses answers its own reason too; none is a fault.
  test "each refusal answers its own reason, an agent unpaired on the way included", c do
    {:ok, agent} = Keyfleet.Agents.with_pairing(agent(c))
    answer = &Answer.answer(:assign_agent, Map.put(&1, "fleet_id", @fleet), agent, nil)

    for {params, status, code} <- [
          {%{"token_id" => 9, "agent_wallet" => "0xab"}, 422, "invalid_request"},
          {%{"token_id" => 0, "agent_wallet" => c.wallet}, 422, "invalid_request"},
          {%{"token_id" => 4, "agent_wallet" => c.wallet}, 409, "key_not_held"},
          {%{"token_id" => 9, "agent_wallet" => @other}, 409, "agent_unknown"}
        ] do
      assert {^status, %{error: %{code: ^code}}, nil} = answer.(params), inspect(params)
    end

    # Unpaired after its request was signed, it puts no agent on a Key.
    person = %RegentAgents.Person{privy_user_id: agent.privy_user_id}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)
    :ok = RegentAgents.unpair_agent(Enum.find(agents, &(&1.wallet == c.wallet)), actor: person)

    assert {403, %{error: %{code: "agent_not_paired"}}, nil} =
             answer.(%{"token_id" => 9, "agent_wallet" => @second})

    assert Keys.agent_keys_of_person!(actor: agent) == []
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

  defp path(suffix \\ ""), do: "/api/v1/agent/fleets/{fleet_id}/agent_keys" <> suffix

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

  defp post!(c, path, body) do
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 152}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
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
