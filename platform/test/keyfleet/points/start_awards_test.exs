defmodule Keyfleet.Points.StartAwardsTest do
  # Invariant: an account, its linked social accounts and its paired agent from
  # before the Points start earn their one-time awards at the start, once,
  # through this site's own checks, without the person doing anything; those
  # from after the start that Points has not recorded earn them once, at their
  # own time, and a run adds nothing for what is already recorded; an account
  # another site already recorded for a rule is not offered it again; a social
  # account linked in place of an earlier one after the start is not held from
  # before it; and a social account refused because it changed hands earns once,
  # for its present holder.
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  import Ecto.Query, only: [from: 2]
  require Ash.Query
  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession
  alias Keyfleet.Actors.System
  alias Keyfleet.Repo
  alias RegentPoints.{Entry, Event, IntakeWorker, StartAwards, Store}

  @rules ~w(account.activated social.x social.github social.farcaster agent.activated)

  defmodule Elsewhere do
    @moduledoc false
    # Another site's own check of its award, which accepted it for the account
    # the event was recorded for.
    def verify(%{"source_app" => app, "source_kind" => kind, "source_event_key" => key}) do
      [%{account_id: account_id}] =
        Event
        |> Ash.Query.filter(
          source_app == ^app and source_kind == ^kind and source_event_key == ^key
        )
        |> Ash.read!(actor: Store.system())

      {:ok, %{account_id: account_id}}
    end
  end

  setup do
    previous =
      Map.new(
        [:starts_at, :approved_rules, :adapters],
        &{&1, Application.get_env(:regent_points, &1)}
      )

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

    # Signing in again with the same X account after the start keeps its time.
    assert {:ok, _account, []} =
             did |> session([%{x | username: "renamed"}]) |> VerifiedSession.establish()

    assert all_enqueued(worker: IntakeWorker) == []

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

  test "an X account linked in place of another after the start is offered as it is linked" do
    [before, replacement] = [social(:x), social(:x)]
    did = "did:privy:replaced-after-start-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session([before]) |> VerifiedSession.establish()

    start = after_clock(account)
    Application.put_env(:regent_points, :starts_at, start)
    Application.put_env(:regent_points, :approved_rules, @rules)

    # After the start the person replaces the X account; the sign-in offers it.
    assert {:ok, _account, []} = did |> session([replacement]) |> VerifiedSession.establish()
    assert offered(["x:" <> replacement.subject]) == ["x:" <> replacement.subject]

    # The start awards offer the account, and the new X account again, since Points
    # has not recorded it yet; neither X account as held before the start.
    assert :ok = perform_job(StartAwards, %{})
    assert offered([to_string(account.id)]) == [to_string(account.id)]
    assert offered(["x:" <> before.subject]) == []

    assert offered(["x:" <> replacement.subject]) ==
             List.duplicate("x:" <> replacement.subject, 2)

    assert %{failure: 0} = Oban.drain_queue(queue: :points, with_recursion: true)
    link = Accounts.get_linked_identity_by_subject!(:x, replacement.subject, actor: %System{})
    assert DateTime.after?(link.inserted_at, start)

    assert [{"account.activated", 25_000_000, activated_at}, {"social.x", 10_000_000, earned_at}] =
             entries(account.id) |> Enum.map(&{&1.rule_id, &1.points_micro_delta, &1.earned_at})

    assert DateTime.compare(activated_at, start) == :eq
    assert DateTime.compare(earned_at, link.inserted_at) == :eq
  end

  test "an account made after the start, before the site switched Points on, earns once at its own time" do
    switched_on_late("account.activated", fn name ->
      did = "did:privy:joined-after-start-#{name}-" <> Ecto.UUID.generate()
      assert {:ok, account, []} = did |> session([]) |> VerifiedSession.establish()
      after_clock(account)
      saved = Accounts.points_account!(account.id, actor: %System{})
      {account.id, to_string(account.id), saved.created_at}
    end)
  end

  test "an X account linked after the start, before the site switched Points on, earns once at its own time" do
    switched_on_late("social.x", fn name ->
      x = social(:x)
      did = "did:privy:linked-after-start-#{name}-" <> Ecto.UUID.generate()
      assert {:ok, account, []} = did |> session([x]) |> VerifiedSession.establish()
      link = Accounts.get_linked_identity_by_subject!(:x, x.subject, actor: %System{})
      {account.id, "x:" <> x.subject, link.inserted_at}
    end)
  end

  test "an agent paired after the start, before the site switched Points on, earns once at its own time" do
    switched_on_late("agent.activated", fn name ->
      did = "did:privy:paired-after-start-#{name}-" <> Ecto.UUID.generate()
      assert {:ok, account, []} = did |> session([]) |> VerifiedSession.establish()
      code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: did})

      pairing =
        RegentAgents.pair_agent!(code.code, "Agent", :codex,
          actor: %RegentAgents.Agent{wallet: wallet()}
        )

      {:ok, history} = RegentAgents.pairing_history(pairing.id)
      {account.id, pairing.id, history.paired_at}
    end)
  end

  test "a social account refused because it changed hands is offered again by the next run, and its present holder earns it once" do
    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -60))
    Application.put_env(:regent_points, :approved_rules, ["social.x"])
    x = social(:x)
    key = "x:" <> x.subject

    [first, second] =
      for name <- ~w(first second), do: "did:privy:changed-hands-#{name}-" <> Ecto.UUID.generate()

    assert {:ok, account, []} = first |> session([x]) |> VerifiedSession.establish()
    assert {:ok, other, []} = second |> session([]) |> VerifiedSession.establish()

    # One pass checks the first person's offer; its award waits.
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :points)

    # The first person lets the X account go and the second links it. The second
    # person's offer is checked while the first award still waits, so it is not
    # recorded.
    assert {:ok, _account, []} = first |> session([]) |> VerifiedSession.establish()
    assert {:ok, _other, []} = second |> session([x]) |> VerifiedSession.establish()

    assert [offer] =
             Enum.filter(
               all_enqueued(worker: IntakeWorker),
               &(&1.args["source_event_key"] == key)
             )

    check_now(offer)
    assert events(other.id, "social.x") == []

    # The first award is refused: the X account now names the second person.
    assert %{failure: 0} = drain()
    assert events(account.id, "social.x") == [{"keyfleet", :rejected}]
    assert entries(account.id, "social.x") == []
    assert entries(other.id, "social.x") == []

    # The next start run offers it for its present holder, who earns it once, at
    # the time they linked it.
    assert :ok = perform_job(StartAwards, %{})
    assert offered([key]) == [key]
    assert %{failure: 0} = drain()

    link = Accounts.get_linked_identity_by_subject!(:x, x.subject, actor: %System{})
    assert [%{earned_at: earned_at}] = entries(other.id, "social.x")
    assert DateTime.compare(earned_at, link.inserted_at) == :eq
    assert entries(account.id, "social.x") == []
    assert events(other.id, "social.x") == [{"keyfleet", :confirmed}]

    # A second run the same day adds nothing.
    assert :ok = perform_job(StartAwards, %{})
    assert offered([key]) == []
    assert [_entry] = entries(other.id, "social.x")
  end

  # Points started a minute ago and this site switches `rule` on only now. `act`
  # does the rule's action for a new person and answers their account id, the
  # source key and when it was done: the first person before the switch, so no
  # save offers it, and the second after it, so their save does.
  defp switched_on_late(rule, act) do
    start = DateTime.add(DateTime.utc_now(), -60)
    Application.put_env(:regent_points, :starts_at, start)
    {late, late_key, done_at} = act.("late")
    Application.put_env(:regent_points, :approved_rules, [rule])
    {live, live_key, _done_at} = act.("live")

    # The second person's offer is checked and awarded before the start run.
    assert offered([late_key, live_key]) == [live_key]
    assert %{failure: 0} = drain()

    # The run offers the first person's, once, and not the second person's again.
    assert :ok = perform_job(StartAwards, %{})
    assert offered([late_key, live_key]) == [late_key]
    assert %{failure: 0} = drain()

    assert [%{earned_at: earned_at}] = entries(late, rule)
    assert DateTime.after?(earned_at, start)
    assert DateTime.compare(earned_at, done_at) == :eq
    assert [_entry] = entries(live, rule)

    # A second run the same day finds both recorded and adds nothing.
    assert :ok = perform_job(StartAwards, %{})
    assert offered([late_key, live_key]) == []
    assert [_entry] = entries(late, rule)
    assert [_entry] = entries(live, rule)
  end

  # Checks one waiting offer now, ahead of work queued before it, as another node
  # may, and marks its job done.
  defp check_now(job) do
    assert :ok = perform_job(IntakeWorker, job.args)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), [set: [state: "completed"]],
      prefix: "keyfleet_app"
    )
  end

  defp drain, do: Oban.drain_queue(queue: :points, with_recursion: true)

  # The offers waiting for these source keys.
  defp offered(keys) do
    for %{args: %{"source_event_key" => key}} <- all_enqueued(worker: IntakeWorker),
        key in keys,
        do: key
  end

  # What another site's award of a linked X account leaves in the shared ledger:
  # its event and its entry, under that site's name, earned at the start, which
  # its own source accepted.
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

    adapters = Application.get_env(:regent_points, :adapters)
    Application.put_env(:regent_points, :adapters, Map.put(adapters, "social.x", Elsewhere))

    assert {:ok, %{status: :confirmed}} =
             RegentPoints.process_event(event.id, actor: Store.system())

    Application.put_env(:regent_points, :adapters, adapters)
  end

  defp entries(account_id) do
    Entry
    |> Ash.Query.filter(account_id == ^account_id)
    |> Ash.Query.sort(rule_id: :asc)
    |> Ash.read!(actor: Store.system())
  end

  defp entries(account_id, rule), do: Enum.filter(entries(account_id), &(&1.rule_id == rule))

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
