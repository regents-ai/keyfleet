defmodule Keyfleet.AgentKeyTest do
  @moduledoc """
  A person puts each of their paired agents on one of their Keys in a fleet.
  The agent then writes as that Key, and holds it alone, while the person's
  wallets hold it and that pairing lasts; their other agents and the person
  keep the person's Key. A Key that changes hands, even between the person's
  own wallets, loses its agent, which stays paired. Only the person, or an
  agent of theirs, does it, only on a Key their wallets hold and only with an
  agent paired with them now; an agent of theirs only puts an agent that is on
  no Key onto a Key with none. A refused write changes nothing.
  """
  use ExUnit.Case, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Errors.{AgentUnknownError, KeyNotHeldError, PersonOnlyError}
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    # The person's two wallets hold Keys 25, 41 and 60; another person's holds 7.
    epoch!(25, wallet("a"))
    epoch!(41, wallet("b"))
    epoch!(60, wallet("a"))
    epoch!(7, wallet("c"))

    person = person!("did:privy:agent-keys", [wallet("a"), wallet("b")])
    other = person!("did:privy:agent-keys-other", [wallet("c")])

    %{
      person: person,
      astra: pair!("did:privy:agent-keys", "Astra", wallet("1")),
      bolt: pair!("did:privy:agent-keys", "Bolt", wallet("2")),
      other: other,
      cato: pair!("did:privy:agent-keys-other", "Cato", wallet("3"))
    }
  end

  test "an agent put on a Key writes as it alone; the person's other agent keeps their Key", c do
    assert Keys.identity(c.astra, @fleet) == %{
             token_id: 25,
             wallet: wallet("a"),
             for_person: true
           }

    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)

    assert Keys.identity(c.astra, @fleet) == %{
             token_id: 41,
             wallet: wallet("b"),
             for_person: true
           }

    assert Keys.held_keys(c.astra, @fleet) == [
             %{token_id: 41, ownership_epoch: 1, wallet: wallet("b"), for_person: true}
           ]

    assert post!(c.astra, "On my Key") |> written_as() == {41, wallet("b")}
    assert listed_key(c.astra) == 41

    assert Keys.identity(c.bolt, @fleet) == %{token_id: 25, wallet: wallet("a"), for_person: true}
    assert post!(c.bolt, "On theirs") |> written_as() == {25, wallet("a")}
    assert listed_key(c.bolt) == 25
    assert Keys.identity(c.person, @fleet) == %{token_id: 25, wallet: wallet("a")}

    assert on_keys(c.person) == %{41 => "Astra"}
  end

  # The workspace check: the agent first passes as its person's Key, then,
  # once on a Key, as that Key alone; the person's other agent still passes as
  # their Key.
  test "an agent on a Key passes the workspace check as it and as no other Key of its person's",
       c do
    ChainHelpers.deploy!(@fleet)

    assert {:ok, _command} = KeyActor.command(c.astra, @fleet, 25, "c-1", 1_000)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)

    assert {:ok, %{auth: %{kind: "agent", operator_wallet: operator}, principal: principal}} =
             KeyActor.command(c.astra, @fleet, 41, "c-2", 1_000)

    assert operator == wallet("1")
    assert String.ends_with?(principal, ":41@1/agent:#{wallet("1")}")

    for token_id <- [25, 60] do
      assert {:error, %NotKeyHolderError{fleet_id: @fleet, token_id: ^token_id}} =
               KeyActor.command(c.astra, @fleet, token_id, "c-3", 1_000)
    end

    assert {:ok, _command} = KeyActor.command(c.bolt, @fleet, 25, "c-4", 1_000)
  end

  test "an agent of the person's puts another of theirs on a Key, as the person would", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("2"), actor: c.astra)

    assert Keys.identity(c.bolt, @fleet) == %{token_id: 60, wallet: wallet("a"), for_person: true}
    assert on_keys(c.astra) == %{60 => "Bolt"}
  end

  test "putting an agent on another Key moves it, and a Key's new agent replaces the one there",
       c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("1"), actor: c.person)

    assert on_keys(c.person) == %{60 => "Astra"}
    assert Keys.identity(c.astra, @fleet).token_id == 60

    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("2"), actor: c.person)

    assert on_keys(c.person) == %{60 => "Bolt"}
    assert Keys.identity(c.astra, @fleet).token_id == 25
    assert Keys.identity(c.bolt, @fleet).token_id == 60

    # Naming no agent takes the Key's agent off.
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, nil, actor: c.person)

    assert on_keys(c.person) == %{}
    assert Keys.identity(c.bolt, @fleet).token_id == 25
  end

  test "once the Key leaves the person's wallets, its agent writes as their Key again", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)

    epoch!(41, wallet("c"), ownership_epoch: 2, log_index: 1)

    assert Keys.identity(c.astra, @fleet) == %{
             token_id: 25,
             wallet: wallet("a"),
             for_person: true
           }

    assert Enum.map(Keys.held_keys(c.astra, @fleet), & &1.token_id) == [25, 60]
    assert on_keys(c.person) == %{}

    # Nor does the Key's new holder's agent take it on.
    assert Keys.identity(c.cato, @fleet).token_id == 7
  end

  test "an unpaired agent's Key no longer applies, even once it pairs again", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("2"), actor: c.person)

    person = %RegentAgents.Person{privy_user_id: "did:privy:agent-keys"}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)
    bolt = Enum.find(agents, &(&1.wallet == wallet("2")))
    :ok = RegentAgents.unpair_agent(bolt, actor: person)

    assert Keys.identity(c.bolt, @fleet) == nil
    assert on_keys(c.person) == %{}

    again = pair!("did:privy:agent-keys", "Bolt", wallet("2"))

    assert Keys.identity(again, @fleet) == %{token_id: 25, wallet: wallet("a"), for_person: true}
    assert {:ok, nil} = Keys.assigned_key(again, @fleet)
  end

  test "a Key the person doesn't hold, or an agent not paired with them now, is refused and changes nothing",
       c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)

    # The person's agent on a Key they don't hold, or on none issued.
    for token_id <- [7, 999] do
      assert {:error, %Ash.Error.Invalid{errors: [%KeyNotHeldError{}]}} =
               Keys.assign_agent(@fleet, token_id, wallet("2"), actor: c.person)
    end

    # Another person's agent, or a wallet paired with nobody, on the person's Key.
    for agent_wallet <- [wallet("3"), wallet("9")] do
      assert {:error, %Ash.Error.Invalid{errors: [%AgentUnknownError{}]}} =
               Keys.assign_agent(@fleet, 41, agent_wallet, actor: c.person)
    end

    # Another person, or their agent, on the person's Key, or with the person's agent.
    for actor <- [c.other, c.cato] do
      assert {:error, %Ash.Error.Invalid{errors: [%KeyNotHeldError{}]}} =
               Keys.assign_agent(@fleet, 41, wallet("3"), actor: actor)

      assert {:error, %Ash.Error.Invalid{errors: [%AgentUnknownError{}]}} =
               Keys.assign_agent(@fleet, 7, wallet("1"), actor: actor)
    end

    assert {:error, %Ash.Error.Invalid{errors: [%KeyNotHeldError{}]}} =
             Keys.assign_agent(@fleet, 41, nil, actor: c.other)

    assert {:error, %Ash.Error.Forbidden{}} = Keys.assign_agent(@fleet, 41, nil, actor: c.cato)

    # Nobody who speaks for a person.
    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.assign_agent(@fleet, 41, wallet("2"), actor: @system)

    assert on_keys(c.person) == %{41 => "Astra"}
    assert Keys.identity(c.astra, @fleet).token_id == 41
    assert Keys.identity(c.bolt, @fleet).token_id == 25
    assert Keys.identity(c.cato, @fleet).token_id == 7
    assert on_keys(c.other) == %{}
  end

  test "an agent puts an agent on no Key onto a Key with none; only the person moves or takes one off",
       c do
    cass = pair!("did:privy:agent-keys", "Cass", wallet("4"))

    # Itself, and another of the person's agents, each onto a Key with none.
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.astra)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("2"), actor: c.astra)
    assert on_keys(c.person) == %{41 => "Astra", 60 => "Bolt"}

    # Taking an agent off, itself or another, is the person's alone.
    for token_id <- [41, 60] do
      assert {:error, %Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]}} =
               Keys.assign_agent(@fleet, token_id, nil, actor: c.astra)
    end

    # So is moving an agent on a Key, itself or another, or replacing one.
    for {token_id, agent_wallet, actor} <- [
          {25, wallet("1"), c.astra},
          {25, wallet("2"), c.astra},
          {60, wallet("1"), c.astra},
          {41, wallet("4"), c.bolt},
          {41, wallet("4"), cass}
        ] do
      assert {:error, %Ash.Error.Forbidden{errors: [%PersonOnlyError{}]}} =
               Keys.assign_agent(@fleet, token_id, agent_wallet, actor: actor)
    end

    assert on_keys(c.person) == %{41 => "Astra", 60 => "Bolt"}

    # An agent on a Key still puts one on no Key onto a Key with none, and
    # naming the agent a Key already has changes nothing.
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("4"), actor: c.bolt)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.astra)
    assert on_keys(c.person) == %{25 => "Cass", 41 => "Astra", 60 => "Bolt"}

    # The person moves and replaces agents, and takes them off.
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("1"), actor: c.person)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, nil, actor: c.person)
    assert on_keys(c.person) == %{25 => "Astra"}
  end

  test "a Key whose agent was unpaired, or that changed hands, has none", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("2"), actor: c.person)

    # Bolt unpairs, so Key 60 has no agent and Astra puts another there.
    person = %RegentAgents.Person{privy_user_id: "did:privy:agent-keys"}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)
    :ok = RegentAgents.unpair_agent(Enum.find(agents, &(&1.wallet == wallet("2"))), actor: person)
    cass = pair!("did:privy:agent-keys", "Cass", wallet("4"))

    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 60, wallet("4"), actor: c.astra)
    assert on_keys(c.person) == %{41 => "Astra", 60 => "Cass"}

    # Key 41 goes to someone else and comes back. Astra came off it when it
    # left, stays paired, acts as their Key again, and is on no Key, so an
    # agent of theirs may put it on one.
    epoch!(41, wallet("c"), ownership_epoch: 2, log_index: 1)
    assert {:ok, nil} = Keys.assigned_key(c.astra, @fleet)

    assert Keys.identity(c.astra, @fleet) == %{
             token_id: 25,
             wallet: wallet("a"),
             for_person: true
           }

    assert c.astra |> Keys.held_keys(@fleet) |> Enum.map(& &1.token_id) == [25, 60]

    epoch!(41, wallet("b"), ownership_epoch: 3, log_index: 2)
    assert on_keys(c.person) == %{60 => "Cass"}
    assert {:ok, nil} = Keys.assigned_key(c.astra, @fleet)

    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("1"), actor: cass)
    assert on_keys(c.person) == %{25 => "Astra", 60 => "Cass"}
    assert c.person |> rows() |> Map.keys() == [25, 60]

    # Only the person's write takes an agent off a Key.
    [row] = Enum.filter(Keys.agent_keys_of_person!(actor: c.astra), &(&1.token_id == 25))
    assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(row, action: :release, actor: c.astra)
    assert :ok = Ash.destroy(row, action: :release, actor: c.person)
    assert on_keys(c.person) == %{60 => "Cass"}
  end

  test "a Key moved between the person's own wallets loses its agent too", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("1"), actor: c.person)

    assert Keys.identity(c.astra, @fleet) == %{
             token_id: 25,
             wallet: wallet("a"),
             for_person: true
           }

    epoch!(25, wallet("b"), ownership_epoch: 2, log_index: 1)
    assert {:ok, nil} = Keys.assigned_key(c.astra, @fleet)
    assert on_keys(c.person) == %{}

    # Its old place blocks nobody: an agent puts another agent on the Key,
    # and the person puts Astra back.
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("2"), actor: c.astra)
    assert on_keys(c.person) == %{25 => "Bolt"}
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 25, wallet("1"), actor: c.person)
    assert on_keys(c.person) == %{25 => "Astra"}
    assert %{25 => %{ownership_epoch: 2}} = rows(c.person)
  end

  test "each person reads only their own agents' Keys", c do
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 41, wallet("1"), actor: c.person)
    assert {:ok, _assigned} = Keys.assign_agent(@fleet, 7, wallet("3"), actor: c.other)

    assert Enum.map(Keys.agent_keys_of_person!(actor: c.person), & &1.token_id) == [41]
    assert Enum.map(Keys.agent_keys_of_person!(actor: c.cato), & &1.token_id) == [7]
    assert {:ok, nil} = Keys.assigned_key(c.bolt, @fleet)
    assert {:ok, %{token_id: 7}} = Keys.assigned_key(c.cato, @fleet)

    assert {:error, %Ash.Error.Forbidden{}} = Keys.agent_keys_of_person(actor: @system)

    # Which Key any agent is on is read by trusted code alone.
    for actor <- [c.person, c.astra] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Keys.agent_keys_of_agents(@fleet, [wallet("1")], actor: actor)
    end
  end

  defp on_keys(actor) do
    for {{@fleet, token_id}, agent} <- Keys.agents_on_keys(actor, Keys.person_agents(actor)),
        into: %{},
        do: {token_id, agent.name}
  end

  # The person's saved rows, by Key, whether or not their agent still stands there.
  defp rows(actor),
    do: Map.new(Keys.agent_keys_of_person!(actor: actor), &{&1.token_id, &1})

  defp person!(privy_user_id, [first | _] = wallets) do
    privy_user_id
    |> Accounts.register_verified!(first, wallets, actor: @system)
    |> Actors.Human.for_account()
  end

  # An agent paired with the person whose Privy user is `privy_user_id`, as a
  # signed request finds it, with a profile of its own.
  defp pair!(privy_user_id, name, agent_wallet) do
    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: privy_user_id})

    RegentAgents.pair_agent!(code, name, :codex, actor: %RegentAgents.Agent{wallet: agent_wallet})

    {:ok, agent} =
      Keyfleet.Agents.with_pairing(%Actors.Agent{
        wallet_address: agent_wallet,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      })

    Keyfleet.Agents.ensure_profile!(%{name: name, declared_harness: "test"}, actor: agent)
    agent
  end

  defp post!(actor, body) do
    {:ok, message} =
      Rooms.send_message(
        %{fleet_id: @fleet, slug: "general", body: body, idempotency_key: Ash.UUID.generate()},
        actor: actor
      )

    message
  end

  defp written_as(message), do: {message.as_key, message.author_wallet}

  defp listed_key(%Actors.Agent{wallet_address: wallet}),
    do: Enum.find(Keyfleet.Agents.agents_here!(@fleet), &(&1.wallet_address == wallet)).key

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp epoch!(token_id, owner, overrides \\ []) do
    %{
      fleet_id: @fleet,
      token_id: token_id,
      ownership_epoch: 1,
      owner_wallet: owner,
      block_number: 10 + token_id,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
