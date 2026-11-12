defmodule Keyfleet.AgentKeyRaceTest do
  @moduledoc """
  Changes to a person's agents on their Keys at the same moment, each on a
  connection of its own, as two requests are. Two changes about one agent run
  one after the other, so an agent's change that crosses the person's move
  sees where the person put it. Changes about different agents, onto one Key
  or swapping Keys, all land. A Key that changes hands while an agent is put
  on it ends with no agents, whichever is saved first. Everything committed
  here is removed, and the fleet put back unbound, when each test ends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, Actors, ChainHelpers, CommittedAccount, CommittedCatalog, Keys, Repo}
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys.Errors.{KeyNotHeldError, PersonOnlyError}

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

  test "two changes about one agent at the same moment run one after the other", c do
    # The person moves Astra and holds its locks while a second move of
    # Astra waits for the first, then lands.
    {held, release} = hold(fn -> assign(c.first, c.astra, c.person) end)
    assert {:ok, _assigned} = held

    crossing = on_own_connection(fn -> assign(c.second, c.astra, c.person) end)
    refute Task.yield(crossing, 300)

    release.()
    assert {:ok, _assigned} = Task.await(crossing, 10_000)

    assert on_keys(c) == %{c.second => ["Astra"]}
  end

  test "an agent's change that crosses the person's move waits, then is refused", c do
    # The person puts Bolt on the first Key while Astra, an agent of theirs,
    # would put Bolt, still on no Key when it asked, onto the second.
    {held, release} = hold(fn -> assign(c.first, c.bolt, c.person) end)
    assert {:ok, _assigned} = held

    crossing = on_own_connection(fn -> assign(c.second, c.bolt, c.astra) end)
    refute Task.yield(crossing, 300)

    release.()

    assert {:error, %Ash.Error.Forbidden{errors: [%PersonOnlyError{}]}} =
             Task.await(crossing, 10_000)

    assert on_keys(c) == %{c.first => ["Bolt"]}
  end

  test "agents put on one Key, or swapping Keys, at the same moment all land", c do
    assert [{:ok, _}, {:ok, _}] =
             race([
               fn -> assign(c.first, c.astra, c.person) end,
               fn -> assign(c.first, c.bolt, c.astra) end
             ])

    assert on_keys(c) == %{c.first => ["Astra", "Bolt"]}

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
      assert on_keys(c) == %{astra_to => ["Astra"], bolt_to => ["Bolt"]}, "round #{round}"
    end
  end

  test "a Key that changes hands while an agent is put on it ends with no agents", c do
    elsewhere = random_wallet()

    # The transfer is recorded while the put waits to commit: the put saved
    # the record before it, so the agent is on no Key.
    {held, release} = hold(fn -> assign(c.first, c.astra, c.person) end)
    assert {:ok, _assigned} = held

    assert {:ok, _moved} =
             Task.await(on_own_connection(fn -> record!(c.first, elsewhere, 2) end), 10_000)

    release.()
    assert on_keys(c) == %{}
    assert {:ok, nil} = Sandbox.unboxed_run(Repo, fn -> Keys.assigned_key(c.astra, @fleet) end)

    # The put arrives while the transfer waits to commit: it reads the record
    # before it, and the agent is on no Key once the transfer lands.
    {held, release} = hold(fn -> record!(c.second, elsewhere, 2) end)
    assert {:ok, _moved} = held

    assert {:ok, _assigned} =
             Task.await(on_own_connection(fn -> assign(c.second, c.bolt, c.person) end), 10_000)

    assert on_keys(c) == %{c.second => ["Bolt"]}
    release.()
    assert on_keys(c) == %{}

    # Once the transfer has landed, the Key is not the person's to put agents on.
    assert {:error, %Ash.Error.Invalid{errors: [%KeyNotHeldError{}]}} =
             Sandbox.unboxed_run(Repo, fn -> assign(c.second, c.bolt, c.person) end)
  end

  # A held write runs inside the test's own open transaction, so its pages
  # hear of it before it commits; that is the hold's doing, not the write's.
  defp assign(token_id, %Actors.Agent{wallet_address: wallet}, actor) do
    Keys.assign_agent(@fleet, token_id, wallet,
      actor: actor,
      context: %{warn_on_transaction_hooks?: false}
    )
  end

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
      for {{@fleet, token_id}, on_key} <-
            Keys.agents_on_keys(c.person, Keys.person_agents(c.person)),
          into: %{},
          do: {token_id, Enum.map(on_key, & &1.name)}
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

  defp record!(token_id, owner, epoch \\ 1) do
    Keys.record_epoch(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        log_index: epoch - 1
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
