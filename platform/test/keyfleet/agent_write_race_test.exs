defmodule Keyfleet.AgentWriteRaceTest do
  @moduledoc """
  A project step by an agent and the agent's unpairing at the same moment,
  each on a connection of its own, as two requests are. The step's check
  holds the agent's pairing until the step commits, so the unpair waits for
  it; a step checked after the unpair is refused. Everything committed here
  is removed, and the fleet put back unbound, when the test ends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias Keyfleet.{
    Accounts,
    Actors,
    ChainHelpers,
    CommittedAccount,
    CommittedCatalog,
    Keys,
    Projects,
    Repo
  }

  alias Keyfleet.Fleets.Fleet

  @fleet "fibonacci_syndicate"
  # The fleet's `general` project is held by Key 3.
  @token_id 3

  setup do
    person_id = "did:privy:agent-write-race-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    person_wallet = random_wallet()
    token_id = @token_id

    added_fleets = Sandbox.unboxed_run(Repo, &CommittedCatalog.commit!/0)
    general = Sandbox.unboxed_run(Repo, &ensure_general/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        clean_up(person_id, token_id)
        put_back(general)
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
      record!(token_id, person_wallet)

      Accounts.register_verified!(person_id, person_wallet, [person_wallet],
        actor: %Actors.System{}
      )

      %{person_id: person_id, agent: pair!(person_id), token_id: token_id}
    end)
  end

  test "an agent unpaired while its project step is checked is unpaired once the step commits",
       c do
    {held, release} = hold(fn -> show(c, true) end)
    assert {:ok, %{shown_to_everyone: true}} = held

    unpairing = on_own_connection(fn -> unpair(c) end)
    refute Task.yield(unpairing, 300)

    release.()
    assert :ok = Task.await(unpairing, 10_000)

    # The request read the agent while it was still paired.
    assert {:error, %Ash.Error.Forbidden{}} = Sandbox.unboxed_run(Repo, fn -> show(c, false) end)
  end

  # A held step runs inside the test's own open transaction; that is the
  # hold's doing, not the step's.
  defp show(c, shown?) do
    Projects.show_project(@fleet, c.token_id, "general", shown?,
      actor: c.agent,
      context: %{warn_on_transaction_hooks?: false}
    )
  end

  # The fleet's `general`, committed here unless the database holds it
  # already, as the local database's own setup leaves it: what the test
  # changes of it, or the project itself if it made it, is put back.
  defp ensure_general do
    case general_row() do
      [shown] ->
        {:had, shown}

      [] ->
        Projects.bootstrap_general!([@fleet])
        :made
    end
  end

  defp put_back({:had, shown}) do
    Repo.update_all(general_query(), set: [shown_to_everyone: shown])
  end

  defp put_back(:made), do: Repo.delete_all(general_query())

  defp general_row, do: Repo.all(select(general_query(), [project], project.shown_to_everyone))

  defp general_query,
    do:
      from(project in "projects",
        prefix: "keyfleet_app",
        where: project.fleet_id == ^@fleet and project.name == "general"
      )

  defp unpair(c) do
    person = %RegentAgents.Person{privy_user_id: c.person_id}
    {:ok, [agent]} = RegentAgents.list_my_agents(actor: person)
    RegentAgents.unpair_agent(agent, actor: person)
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

  defp on_own_connection(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      fun.()
    end)
  end

  defp pair!(person_id) do
    wallet = random_wallet()

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person_id})

    RegentAgents.pair_agent!(code, "Astra", :codex, actor: %RegentAgents.Agent{wallet: wallet})

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
  defp clean_up(person_id, token_id) do
    Repo.transaction(fn ->
      Repo.query!("DELETE FROM regent_agents.paired_agents WHERE privy_user_id = $1", [person_id])

      Repo.query!("DELETE FROM regent_agents.pairing_history WHERE privy_user_id = $1", [
        person_id
      ])

      Repo.query!("DELETE FROM regent_agents.pairing_codes WHERE privy_user_id = $1", [person_id])
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs")

      Repo.query!(
        "DELETE FROM keyfleet_app.key_attachments WHERE fleet_id = $1 AND token_id = $2",
        [@fleet, token_id]
      )

      Repo.query!("DELETE FROM keyfleet_app.chain_cursors WHERE fleet_id = $1", [@fleet])
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs")
    end)
  end

  defp random_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
