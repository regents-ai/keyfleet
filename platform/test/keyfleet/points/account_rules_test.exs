defmodule Keyfleet.Points.AccountRulesTest do
  # Invariant: a new account, each social account a person links and a person's
  # first paired agent each earn their one-time award once, in one entry,
  # whichever site records it. Each is offered inside the save that makes it,
  # so a save that rolls back offers nothing, a sign-in that changes nothing
  # offers nothing more, a social account that replaces another is offered as
  # newly linked, and a rule that is off offers nothing. Points asks the source
  # when it checks the offer and again just before it writes the award.
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  import Ash.Signals.Test
  require Ash.Query
  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.{Signals, VerifiedSession}
  alias Keyfleet.Actors.System
  alias Keyfleet.Repo
  alias RegentPoints.{Entry, Event, IntakeWorker, Rejection, Store}

  @rules ~w(account.activated social.x social.github social.farcaster agent.activated)

  defmodule Unreachable do
    @moduledoc false
    # A source that cannot answer, as when its database is out of reach.
    def verify(_reference), do: {:retry, :source_unreachable}
  end

  defmodule Elsewhere do
    @moduledoc false
    # Another site's own check of its award, which accepted it.
    def verify(_reference), do: {:ok, %{}}
  end

  setup do
    previous = Map.new([:starts_at, :approved_rules, :adapters], &{&1, points_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> put_points_env(key, value) end) end)

    put_points_env(:starts_at, DateTime.add(DateTime.utc_now(), -1, :day))
    put_points_env(:approved_rules, @rules)
    :ok
  end

  test "a new account earns 25 once; a sign-in that rolls back or changes nothing offers nothing" do
    did = "did:privy:points-account-" <> Ecto.UUID.generate()

    Repo.transaction(fn ->
      did |> session([]) |> VerifiedSession.establish()
      Repo.rollback(:undone)
    end)

    assert offers("account.activated") == []

    {:ok, account, []} =
      assert_emits_signal(Signals, :account_registered, %{account_id: registered}, fn ->
        did |> session([]) |> VerifiedSession.establish()
      end)

    assert registered == account.id

    {:ok, %{id: same}, []} =
      refute_emits_signal(Signals, :account_registered, fn ->
        did |> session([]) |> VerifiedSession.establish()
      end)

    assert same == account.id

    assert [%{args: %{"source_app" => "regents", "source_event_key" => key}}] =
             offers("account.activated")

    assert key == to_string(account.id)

    settle_clock(account)
    assert %{success: 2, failure: 0} = drain()
    assert entries(account.id) == [{"account.activated", 25_000_000, "regents"}]
  end

  test "a linked social account earns 10 once, and nothing more for a second person" do
    x = social(:x)
    first = "did:privy:points-social-first-" <> Ecto.UUID.generate()
    second = "did:privy:points-social-second-" <> Ecto.UUID.generate()

    {:ok, account, []} =
      assert_emits_signal(Signals, :social_linked, %{provider: :x, subject: subject}, fn ->
        first |> session([x]) |> VerifiedSession.establish()
      end)

    assert subject == x.subject
    assert [%{args: %{"source_event_key" => key}}] = offers("social.x")
    assert key == "x:" <> x.subject

    settle_clock(account)
    assert %{failure: 0} = drain()
    assert entries(account.id, "social.x") == [{"social.x", 10_000_000, "keyfleet"}]
    linked = link(x)

    # Signing in with the same X account refreshes the link: it keeps the time it
    # was linked, nothing is announced and nothing is offered.
    {:ok, _account, []} =
      refute_emits_signal(Signals, :social_linked, fn ->
        first |> session([%{x | username: "renamed"}]) |> VerifiedSession.establish()
      end)

    assert all_enqueued(worker: IntakeWorker) == []
    assert %{id: id, inserted_at: inserted_at, username: "renamed"} = link(x)
    assert {id, inserted_at} == {linked.id, linked.inserted_at}

    # The first person lets the X account go, and a second person links it.
    assert {:ok, _account, []} = first |> session([]) |> VerifiedSession.establish()
    assert {:ok, other, []} = second |> session([]) |> VerifiedSession.establish()

    Accounts.upsert_linked_identity!(
      Map.merge(x, %{verified_at: DateTime.utc_now(), metadata: %{}, human_account_id: other.id}),
      actor: %System{}
    )

    assert [_offer] = offers("social.x")

    settle_clock(other)
    assert %{failure: 0} = drain()
    assert entries(other.id, "social.x") == []
    assert "source_identity_conflict" in rejections(key)
  end

  test "a replaced social account is linked anew; it earns only for an account yet to earn the rule" do
    [first, second] = [social(:x), social(:x)]
    did = "did:privy:points-replaced-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session([first]) |> VerifiedSession.establish()
    settle_clock(account)
    assert %{failure: 0} = drain()
    assert entries(account.id, "social.x") == [{"social.x", 10_000_000, "keyfleet"}]
    linked = link(first)

    # The person replaces their X account: the new one is linked now, and announced.
    replaced_at = DateTime.utc_now()

    {:ok, _account, []} =
      assert_emits_signal(Signals, :social_linked, %{subject: subject}, fn ->
        did |> session([second]) |> VerifiedSession.establish()
      end)

    assert subject == second.subject
    replacement = link(second)
    assert replacement.id == linked.id
    assert DateTime.compare(replacement.inserted_at, replaced_at) != :lt

    # The account has had its X award, so the replacement earns nothing more.
    assert [_offer] = offers("social.x")
    assert %{failure: 0} = drain()
    assert entries(account.id, "social.x") == [{"social.x", 10_000_000, "keyfleet"}]

    # Another person linked an X account while that rule was off, so never earned
    # it; the account replacing it earns, once, from when it was linked.
    put_points_env(:approved_rules, @rules -- ["social.x"])
    [early, later] = [social(:x), social(:x)]
    other_did = "did:privy:points-replaced-other-" <> Ecto.UUID.generate()
    assert {:ok, other, []} = other_did |> session([early]) |> VerifiedSession.establish()
    settle_clock(other)
    assert %{failure: 0} = drain()

    put_points_env(:approved_rules, @rules)
    assert {:ok, _other, []} = other_did |> session([later]) |> VerifiedSession.establish()
    assert %{failure: 0} = drain()
    assert %{failure: 0, success: 0} = drain()

    assert [%{points_micro_delta: 10_000_000, earned_at: earned_at}] =
             Entry
             |> Ash.Query.filter(account_id == ^other.id and rule_id == "social.x")
             |> Ash.read!(actor: Store.system())

    assert DateTime.compare(earned_at, link(later).inserted_at) == :eq
  end

  test "a social account another site already rewarded earns nothing more here" do
    [mine, theirs] = [social(:x), social(:x)]

    [person, someone, newcomer] =
      for name <- ~w(person someone newcomer),
          do: "did:privy:points-#{name}-" <> Ecto.UUID.generate()

    [person_id, someone_id] =
      for did <- [person, someone] do
        assert {:ok, account, []} = did |> session([]) |> VerifiedSession.establish()
        account.id
      end

    # Another site, under its own name, rewarded the person's X account, and
    # someone else's X account too.
    rewarded_elsewhere(person_id, "x:" <> mine.subject)
    rewarded_elsewhere(someone_id, "x:" <> theirs.subject)

    # Here the person links the same X account, and a newcomer links the other.
    assert {:ok, _account, []} = person |> session([mine]) |> VerifiedSession.establish()

    assert {:ok, %{id: newcomer_id} = account, []} =
             newcomer |> session([theirs]) |> VerifiedSession.establish()

    settle_clock(account)
    assert %{failure: 0} = drain()

    # The person: nothing more is recorded; their one award is the other site's.
    assert entries(person_id, "social.x") == [{"social.x", 10_000_000, "regents"}]
    assert events(person_id, "social.x") == [{"regents", :confirmed}]

    # The newcomer: recorded here, and held to nothing, because that X account
    # has had its award.
    assert entries(newcomer_id, "social.x") == []
    assert events(newcomer_id, "social.x") == [{"keyfleet", :capped}]
  end

  test "a person's first paired agent earns 25 once; a second pairing earns nothing more" do
    {account, person} = account()
    wallets = for name <- ["First", "Second"], do: pair(person, name).wallet

    assert length(offers("agent.activated")) == 2
    assert %{failure: 0} = drain()

    assert [%{actor_kind: "agent", actor_id: wallet, points_micro_delta: 25_000_000}] =
             Entry
             |> Ash.Query.filter(account_id == ^account.id and rule_id == "agent.activated")
             |> Ash.read!(actor: Store.system())

    assert wallet in wallets
    assert events(account.id, "agent.activated") == [{"keyfleet", :confirmed}]
  end

  # Points asks the source when it checks the offer and again just before it
  # writes the award. A pairing is kept after an unpair, so an agent unpaired in
  # between still earns; a link removed in between earns nothing, and neither
  # does one removed before the check.
  test "the source is asked again just before the award" do
    {account, person} = account()
    paired = pair(person, "Agent")

    # One pass checks the account's and the pairing's offers; the next awards them.
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :points)
    :ok = RegentAgents.unpair_agent(paired, actor: person)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :points)
    assert entries(account.id, "agent.activated") == [{"agent.activated", 25_000_000, "keyfleet"}]

    did = "did:privy:points-unlinked-" <> Ecto.UUID.generate()
    [x, github] = [social(:x), social(:github)]
    assert {:ok, linked, []} = did |> session([x]) |> VerifiedSession.establish()
    settle_clock(linked)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :points)

    # The X account goes after the check, and the GitHub one before it.
    assert {:ok, _account, []} = did |> session([github]) |> VerifiedSession.establish()
    assert {:ok, _account, []} = did |> session([]) |> VerifiedSession.establish()
    assert %{failure: 0} = drain()

    assert entries(linked.id) == [{"account.activated", 25_000_000, "regents"}]
    assert events(linked.id, "social.x") == [{"keyfleet", :rejected}]
    assert "link_not_found" in rejections("x:" <> x.subject)
    assert "link_not_found" in rejections("github:" <> github.subject)
  end

  test "a source that cannot answer just before the award earns once it can" do
    x = social(:x)
    did = "did:privy:points-award-retry-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session([x]) |> VerifiedSession.establish()
    settle_clock(account)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :points)

    # The offers passed their check; the link's source cannot answer at its award.
    adapters = points_env(:adapters)
    put_points_env(:adapters, Map.put(adapters, "social.x", Unreachable))
    assert %{success: 1, failure: 1} = Oban.drain_queue(queue: :points)
    assert entries(account.id, "social.x") == []
    assert events(account.id, "social.x") == [{"keyfleet", :pending}]

    put_points_env(:adapters, adapters)
    assert %{success: 1, failure: 0} = drain(with_scheduled: true)
    assert %{success: 0, failure: 0} = drain(with_scheduled: true)
    assert entries(account.id, "social.x") == [{"social.x", 10_000_000, "keyfleet"}]
    assert events(account.id, "social.x") == [{"keyfleet", :confirmed}]
  end

  test "a source that cannot answer leaves the offer to Oban and earns once when it can" do
    adapters = points_env(:adapters)
    put_points_env(:adapters, Map.put(adapters, "social.x", Unreachable))

    x = social(:x)
    did = "did:privy:points-retry-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session([x]) |> VerifiedSession.establish()
    settle_clock(account)

    # The account earns; the link's check fails and Oban keeps it to try again.
    assert %{success: 2, failure: 1, discard: 0} = drain()
    assert entries(account.id, "social.x") == []

    put_points_env(:adapters, adapters)
    assert %{success: 2, failure: 0} = drain(with_scheduled: true)
    assert %{success: 0, failure: 0} = drain(with_scheduled: true)
    assert entries(account.id, "social.x") == [{"social.x", 10_000_000, "keyfleet"}]
  end

  test "a rule that is off offers nothing; with no start an offer is turned down" do
    put_points_env(:approved_rules, [])
    {_account, person} = account([social(:github)])
    pair(person, "Agent")
    assert all_enqueued(worker: IntakeWorker) == []

    # Without a start the approved rules still queue their offers, and Points
    # turns each down when it checks it.
    put_points_env(:approved_rules, @rules)
    put_points_env(:starts_at, nil)
    {account, _person} = account([social(:x)])
    assert length(all_enqueued(worker: IntakeWorker)) == 2

    assert %{failure: 0} = drain()
    assert entries(account.id) == []
    assert "rule_not_active" in rejections(to_string(account.id))
  end

  defp account(linked_socials \\ []) do
    did = "did:privy:points-person-" <> Ecto.UUID.generate()
    assert {:ok, account, []} = did |> session(linked_socials) |> VerifiedSession.establish()
    settle_clock(account)
    {account, %RegentAgents.Person{privy_user_id: did}}
  end

  defp pair(person, name) do
    code = RegentAgents.issue_pairing_code!(actor: person)

    RegentAgents.pair_agent!(code.code, name, :codex,
      actor: %RegentAgents.Agent{wallet: wallet()}
    )
  end

  # What another site's award of a linked X account leaves in the shared ledger:
  # its event and its entry, under that site's name, which its own source accepted.
  defp rewarded_elsewhere(account_id, key) do
    start = points_env(:starts_at)
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

    adapters = points_env(:adapters)
    put_points_env(:adapters, Map.put(adapters, "social.x", Elsewhere))

    assert {:ok, %{status: :confirmed}} =
             RegentPoints.process_event(event.id, actor: Store.system())

    put_points_env(:adapters, adapters)
  end

  defp link(%{provider: provider, subject: subject}),
    do: Accounts.get_linked_identity_by_subject!(provider, subject, actor: %System{})

  defp offers(rule),
    do: Enum.filter(all_enqueued(worker: IntakeWorker), &(&1.args["rule_id"] == rule))

  defp drain(opts \\ []),
    do: Oban.drain_queue(Keyword.merge([queue: :points, with_recursion: true], opts))

  defp entries(account_id, rule \\ nil) do
    Entry
    |> Ash.Query.filter(account_id == ^account_id)
    |> Ash.Query.sort(rule_id: :asc)
    |> Ash.read!(actor: Store.system())
    |> Enum.filter(&(rule in [nil, &1.rule_id]))
    |> Enum.map(&{&1.rule_id, &1.points_micro_delta, &1.source_app})
  end

  defp events(account_id, rule) do
    Event
    |> Ash.Query.filter(account_id == ^account_id and rule_id == ^rule)
    |> Ash.read!(actor: Store.system())
    |> Enum.map(&{&1.source_app, &1.processing_status})
  end

  defp rejections(key) do
    Rejection
    |> Ash.read!(actor: Store.system())
    |> Enum.filter(&(&1.source["source_event_key"] == key))
    |> Enum.map(& &1.reason_code)
  end

  # The shared account table keeps its time to the second, rounded, so a new
  # account can be up to half a second ahead of the clock; Points' check waits
  # for it, and so does the test.
  defp settle_clock(account) do
    account = Accounts.points_account!(account.id, actor: %System{})
    Process.sleep(max(0, DateTime.diff(account.created_at, DateTime.utc_now(), :millisecond) + 1))
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

  defp points_env(key), do: Application.get_env(:regent_points, key)
  defp put_points_env(key, value), do: Application.put_env(:regent_points, key, value)

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
