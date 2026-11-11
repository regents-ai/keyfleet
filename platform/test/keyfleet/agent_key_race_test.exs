defmodule Keyfleet.AgentKeyRaceTest do
  @moduledoc """
  Two changes to a person's agents on their Keys at the same moment, each on
  a connection of its own, as two requests are. A swap runs one change after
  the other and both land. Two agents put on one Key with no agent yet leave
  the first there, and the second change, by the person or by their agent, is
  told to read again and try again. Everything committed here is removed,
  and the fleet put back unbound, when each test ends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ash.Error.Changes.StaleRecord
  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, Actors, ChainHelpers, CommittedAccount, CommittedCatalog, Keys, Repo}
  alias Keyfleet.Fleets.Fleet
  alias KeyfleetWeb.AgentTools.Refused

  @fleet "fibonacci_syndicate"

  setup do
    person_id = "did:privy:agent-key-race-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    person_wallet = random_wallet()
    [first, second] = Enum.sort(for _ <- 1..2, do: :rand.uniform(1_000_000_000) + 1_000_000_000)

    added_fleets = Sandbox.unboxed_run(Repo, &CommittedCatalog.commit!/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        clean_up(person_id, [first, second])
        CommittedAccount.remove!(person_id)

        # Fleets have no action that unbinds a deployment, since the site never
        # does; this teardown puts the test's fleet back unbound directly.
        Repo.update_all(from(fleet in "fleets", where: fleet.id == ^@fleet),
          set: Enum.map(Fleet.deployment_fields(), &{&1, nil})
        )

        CommittedCatalog.remove!(added_fleets)
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      ChainHelpers.deploy!(@fleet)
      ChainHelpers.seed_cursor!(@fleet)
      for token_id <- [first, second], do: record!(token_id, person_wallet)

      person =
        person_id
        |> Accounts.register_verified!(person_wallet, [person_wallet], actor: %Actors.System{})
        |> Actors.Human.for_account()

      %{
        person: person,
        astra: pair!(person_id, "Astra"),
        bolt: pair!(person_id, "Bolt"),
        first: first,
        second: second
      }
    end)
  end

  test "two agents swapping Keys at the same moment both land, one after the other", c do
    put!(c.first, c.astra, c.person)
    put!(c.second, c.bolt, c.person)

    # Astra goes onto Bolt's Key and holds its locks while Bolt goes onto
    # Astra's: the second waits for the first, then lands.
    {held, release} = hold(fn -> assign(c.second, c.astra, c.person) end)
    assert {:ok, _assigned} = held

    crossing = on_own_connection(fn -> assign(c.first, c.bolt, c.person) end)
    refute Task.yield(crossing, 300)

    release.()
    assert {:ok, _assigned} = Task.await(crossing, 10_000)

    assert on_keys(c) == %{c.first => "Bolt", c.second => "Astra"}
  end

  test "swaps sent at the same moment, again and again, all land", c do
    put!(c.first, c.astra, c.person)
    put!(c.second, c.bolt, c.person)

    for round <- 1..10 do
      {astra_to, bolt_to} =
        if rem(round, 2) == 1, do: {c.second, c.first}, else: {c.first, c.second}

      results =
        race([
          fn -> assign(astra_to, c.astra, c.person) end,
          fn -> assign(bolt_to, c.bolt, c.person) end
        ])

      assert [{:ok, _}, {:ok, _}] = results, "round #{round}"
      assert on_keys(c) == %{astra_to => "Astra", bolt_to => "Bolt"}, "round #{round}"
    end
  end

  test "of two agents put on a Key with none at the same moment, the second is told to try again",
       c do
    {held, release} = hold(fn -> assign(c.first, c.astra, c.person) end)
    assert {:ok, _assigned} = held

    crossing = on_own_connection(fn -> assign(c.first, c.bolt, c.person) end)
    refute Task.yield(crossing, 300)

    release.()
    assert {:error, %Ash.Error.Invalid{errors: errors}} = Task.await(crossing, 10_000)
    assert Enum.any?(errors, &match?(%StaleRecord{}, &1))

    assert on_keys(c) == %{c.first => "Astra"}

    # Sent again, it replaces the agent there, as the person asked.
    assert {:ok, _assigned} =
             Sandbox.unboxed_run(Repo, fn -> assign(c.first, c.bolt, c.person) end)

    assert on_keys(c) == %{c.first => "Bolt"}
  end

  test "an agent whose change crossed another for the same Key is answered agent_keys_changed",
       c do
    {held, release} = hold(fn -> assign(c.second, c.astra, c.person) end)
    assert {:ok, _assigned} = held

    crossing =
      on_own_connection(fn ->
        KeyfleetWeb.AgentTools.Keys
        |> Ash.ActionInput.for_action(
          :assign_agent,
          %{fleet_id: @fleet, token_id: c.second, agent_wallet: c.bolt.wallet_address},
          actor: c.bolt,
          context: %{waiter: nil}
        )
        |> Ash.run_action()
      end)

    refute Task.yield(crossing, 300)
    release.()

    assert {:error, %Ash.Error.Invalid{errors: [%Refused{status: 409} = refused]}} =
             Task.await(crossing, 10_000)

    assert refused.body.error.code == "agent_keys_changed"
    assert on_keys(c) == %{c.second => "Astra"}
  end

  defp assign(token_id, %Actors.Agent{wallet_address: wallet}, actor),
    do: Keys.assign_agent(@fleet, token_id, wallet, actor: actor)

  defp put!(token_id, agent, actor) do
    assert {:ok, _assigned} = Sandbox.unboxed_run(Repo, fn -> assign(token_id, agent, actor) end)
  end

  # Runs `write` in a transaction of its own that stays open, holding its
  # locks, until the returned function is called.
  defp hold(write) do
    parent = self()

    holder =
      on_own_connection(fn ->
        Repo.transaction(fn ->
          send(parent, {:held, write.()})

          receive do
            :commit -> :ok
          after
            10_000 -> raise "the held write was never let go"
          end
        end)
      end)

    assert_receive {:held, held}, 10_000

    {held,
     fn ->
       send(holder.pid, :commit)
       Task.await(holder, 10_000)
     end}
  end

  defp race(writes) do
    parent = self()

    callers =
      for write <- writes do
        on_own_connection(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> write.()
          after
            10_000 -> raise "the starting barrier timed out"
          end
        end)
      end

    for _ <- callers, do: assert_receive({:ready, _}, 10_000)
    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 15_000)
  end

  defp on_own_connection(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      fun.()
    end)
  end

  defp on_keys(c) do
    Sandbox.unboxed_run(Repo, fn ->
      for {{@fleet, token_id}, agent} <-
            Keys.agents_on_keys(c.person, Keys.person_agents(c.person)),
          into: %{},
          do: {token_id, agent.name}
    end)
  end

  defp pair!(person_id, name) do
    wallet = random_wallet()

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person_id})

    RegentAgents.pair_agent!(code, name, :codex, actor: %RegentAgents.Agent{wallet: wallet})

    {:ok, agent} =
      Keyfleet.Agents.with_pairing(%Actors.Agent{
        wallet_address: wallet,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      })

    agent
  end

  defp record!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # Key records refuse to be deleted. Their guard is set aside inside this
  # one transaction, which no other connection sees, and is back in place
  # when it commits.
  defp clean_up(person_id, token_ids) do
    Repo.transaction(fn ->
      Repo.query!(
        "DELETE FROM keyfleet_app.agent_keys WHERE human_account_id IN " <>
          "(SELECT id FROM regent_names.platform_human_users WHERE privy_user_id = $1)",
        [person_id]
      )

      Repo.query!("DELETE FROM regent_agents.paired_agents WHERE privy_user_id = $1", [person_id])

      Repo.query!("DELETE FROM regent_agents.pairing_history WHERE privy_user_id = $1", [
        person_id
      ])

      Repo.query!("DELETE FROM regent_agents.pairing_codes WHERE privy_user_id = $1", [person_id])
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs")

      Repo.query!(
        "DELETE FROM keyfleet_app.key_attachments WHERE fleet_id = $1 AND token_id = ANY($2)",
        [@fleet, token_ids]
      )

      Repo.query!("DELETE FROM keyfleet_app.chain_cursors WHERE fleet_id = $1", [@fleet])
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs")
    end)
  end

  defp random_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
