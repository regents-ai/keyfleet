defmodule Keyfleet.Points.StartAwardsTest do
  # Invariant: an account, its linked social accounts and its paired agent from
  # before the Points start earn their one-time awards at the start, once,
  # through this site's own checks, without the person doing anything; an
  # account another site already recorded for a rule is not offered it again.
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  require Ash.Query
  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession
  alias Keyfleet.Actors.System
  alias RegentPoints.{Entry, Event, IntakeWorker, StartAwards, Store}

  @rules ~w(account.activated social.x social.github social.farcaster agent.activated)

  setup do
    previous =
      Map.new([:starts_at, :approved_rules], &{&1, Application.get_env(:regent_points, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)

    # Before the switch nothing is approved: what people do then earns nothing.
    Application.put_env(:regent_points, :starts_at, nil)
    Application.put_env(:regent_points, :approved_rules, [])
  end

  test "what an account had before the start earns once, at the start" do
    x = social(:x)
    did = "did:privy:before-start-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session([x]) |> VerifiedSession.establish()

    code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: did})

    pairing =
      RegentAgents.pair_agent!(code.code, "Early", :codex,
        actor: %RegentAgents.Agent{wallet: wallet()}
      )

    # A second person whose X account another site already recorded and rewarded.
    rewarded = social(:x)
    other_did = "did:privy:before-start-other-" <> Ecto.UUID.generate()
    assert {:ok, other, []} = other_did |> session([rewarded]) |> VerifiedSession.establish()
    assert all_enqueued(worker: IntakeWorker) == []

    start = after_clock(other)
    Application.put_env(:regent_points, :starts_at, start)
    Application.put_env(:regent_points, :approved_rules, @rules)
    rewarded_elsewhere(other.id, "x:" <> rewarded.subject, start)

    assert :ok = perform_job(StartAwards, %{})

    mine = [to_string(account.id), "x:" <> x.subject, pairing.id]
    assert offered(mine) |> Enum.sort() == Enum.sort(mine)
    assert offered(["x:" <> rewarded.subject]) == []

    assert %{failure: 0} = Oban.drain_queue(queue: :points, with_recursion: true)

    assert [
             {"account.activated", 25_000_000},
             {"agent.activated", 25_000_000},
             {"social.x", 10_000_000}
           ] = entries(account.id) |> Enum.map(&{&1.rule_id, &1.points_micro_delta})

    assert Enum.all?(entries(account.id), &(DateTime.compare(&1.earned_at, start) == :eq))
    assert events(other.id, "social.x") == [{"regents", :confirmed}]

    # A later run finds everything already recorded and offers nothing more.
    assert :ok = perform_job(StartAwards, %{})
    assert offered(mine ++ ["x:" <> rewarded.subject, to_string(other.id)]) == []
  end

  # The offers waiting for these source keys.
  defp offered(keys) do
    for %{args: %{"source_event_key" => key}} <- all_enqueued(worker: IntakeWorker),
        key in keys,
        do: key
  end

  # What another site's award of a linked X account leaves in the shared ledger:
  # its event and its entry, under that site's name, earned at the start.
  defp rewarded_elsewhere(account_id, key, start) do
    {:ok, rule} = RegentPoints.Rules.snapshot("social.x", start)

    facts = %{
      source_app: "regents",
      source_kind: "linked_identity",
      source_event_key: key,
      account_id: account_id,
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: start,
      qualified_at: start,
      evidence_ref: "linked_identity:" <> Ecto.UUID.generate(),
      evidence: %{"subject_key" => key}
    }

    RegentPoints.open_account!(%{id: account_id}, actor: Store.system())

    event =
      RegentPoints.create_event!(
        Map.merge(facts, %{
          program_id: RegentPoints.Rules.program(),
          rule_id: "social.x",
          rule_snapshot: rule,
          award_key: Store.digest({"regents", "linked_identity", key, "social.x"}),
          payload_digest: Store.digest(facts)
        }),
        actor: Store.system()
      )

    assert {:ok, %{status: :confirmed}} =
             RegentPoints.process_event(event.id, actor: Store.system())
  end

  defp entries(account_id) do
    Entry
    |> Ash.Query.filter(account_id == ^account_id)
    |> Ash.Query.sort(rule_id: :asc)
    |> Ash.read!(actor: Store.system())
  end

  defp events(account_id, rule) do
    Event
    |> Ash.Query.filter(account_id == ^account_id and rule_id == ^rule)
    |> Ash.read!(actor: Store.system())
    |> Enum.map(&{&1.source_app, &1.processing_status})
  end

  # A start just after the account's time, which the shared account table keeps
  # to the second, rounded, so it can be up to half a second ahead of the clock.
  defp after_clock(account) do
    account = Accounts.points_account!(account.id, actor: %System{})
    Process.sleep(max(0, DateTime.diff(account.created_at, DateTime.utc_now(), :millisecond) + 1))
    DateTime.utc_now()
  end

  defp session(did, linked_socials) do
    wallet = "0x" <> String.slice(Base.encode16(:crypto.hash(:sha, did), case: :lower), 0, 40)

    %RegentPrivy.Session{
      app_id: "test-app",
      session_id: "test-session",
      privy_user_id: did,
      wallet_address: wallet,
      wallet_addresses: [wallet],
      linked_socials: linked_socials,
      issued_at: Elixir.System.system_time(:second),
      expires_at: Elixir.System.system_time(:second) + 3600
    }
  end

  defp social(provider),
    do: %{
      provider: provider,
      subject: "#{provider}-" <> Ecto.UUID.generate(),
      username: "linked",
      display_name: nil
    }

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
