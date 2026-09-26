defmodule Keyfleet.CheckInsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckIn
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Fleets
  alias Keyfleet.Repo

  @fleet "fleet_tech_classic"
  @t0 ~U[2026-09-25 12:00:00.000000Z]

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    {actor, profile} = agent("b", "Bosun")
    %{actor: actor, profile: profile}
  end

  test "scheduled check-ins one interval apart confirm the schedule", %{actor: actor} do
    first = scheduled!(actor, 30)
    assert first.schedule_confirmed_at == nil
    assert first.counted_scheduled_at == first.last_scheduled_at
    assert status(first) == :confirming_schedule

    minutes_pass!(30)
    second = scheduled!(actor, 30)

    assert second.schedule_confirmed_at == second.last_scheduled_at
    assert second.counted_scheduled_at == second.last_scheduled_at
    assert status(second) == :check_ins_working
  end

  test "a ten-minute schedule is confirmed by the check-in ten minutes later", %{actor: actor} do
    scheduled!(actor, 10)
    minutes_pass!(10)

    assert %{schedule_confirmed_at: %DateTime{}, schedule_minutes: 10} = scheduled!(actor, 10)
  end

  test "a check-in too soon after the counted one is not a step in the count", %{actor: actor} do
    first = scheduled!(actor, 30)
    minutes_pass!(3)
    second = scheduled!(actor, 30)

    assert second.schedule_confirmed_at == nil
    assert second.counted_scheduled_at == DateTime.add(first.counted_scheduled_at, -3, :minute)
    assert second.last_scheduled_at != second.counted_scheduled_at
  end

  test "a check-in that ran late still confirms, measured from the counted one", %{actor: actor} do
    # Run 40 minutes late, then on time: 20 minutes apart is too soon, and the
    # next one is 80 minutes after the counted check-in, within 60 plus grace.
    scheduled!(actor, 60)
    minutes_pass!(20)
    assert %{schedule_confirmed_at: nil} = scheduled!(actor, 60)
    minutes_pass!(60)

    assert %{schedule_confirmed_at: %DateTime{}} = scheduled!(actor, 60)
  end

  test "a late check-in keeps the confirmation; a much later one starts it again",
       %{actor: actor} do
    confirm!(actor, 30)

    minutes_pass!(2 * 30 + CheckInStatus.grace_minutes() - 1)
    kept = scheduled!(actor, 30)
    assert kept.schedule_confirmed_at != nil
    assert kept.counted_scheduled_at == kept.last_scheduled_at

    minutes_pass!(2 * 30 + CheckInStatus.grace_minutes() + 1)
    restarted = scheduled!(actor, 30)
    assert restarted.schedule_confirmed_at == nil
    assert restarted.counted_scheduled_at == restarted.last_scheduled_at
  end

  test "a new interval starts the count again", %{actor: actor} do
    confirm!(actor, 30)
    minutes_pass!(30)

    assert %{schedule_minutes: 60, schedule_confirmed_at: nil} = scheduled!(actor, 60)
  end

  test "a schedule with no check-in for twice its interval plus the grace is paused",
       %{actor: actor} do
    confirm!(actor, 60)

    minutes_pass!(2 * 60 + CheckInStatus.grace_minutes() + 1)

    assert status(check_in(actor)) == :paused
  end

  test "check-ins during a conversation are written at most once a minute", %{actor: actor} do
    first = session!(actor)
    assert status(first) == :connected_now

    seconds_pass!(10)
    second = session!(actor)
    assert second.last_session_at == DateTime.add(first.last_session_at, -10, :second)

    seconds_pass!(CheckInStatus.spacing_seconds())
    third = session!(actor)
    assert DateTime.after?(third.last_session_at, second.last_session_at)
    assert third.last_check_in_at == third.last_session_at
  end

  test "a check-in during a conversation is not a step in the scheduled count",
       %{actor: actor} do
    scheduled!(actor, 30)
    minutes_pass!(30)
    during = session!(actor)

    assert during.schedule_confirmed_at == nil
    assert during.last_check_in_at == during.last_session_at
    assert DateTime.before?(during.last_scheduled_at, during.last_session_at)
  end

  test "an agent never writes another agent's check-ins", %{profile: profile} do
    {other, _profile} = agent("c", "Able")

    assert {:error, %Ash.Error.Forbidden{}} =
             CheckIn
             |> Ash.Changeset.for_create(
               :check_in_session,
               %{agent_profile_id: profile.id, fleet_id: @fleet},
               actor: other
             )
             |> Ash.create()

    assert Agents.get_check_in!(profile.id, @fleet) == nil
  end

  test "an agent without a profile has nothing recorded" do
    actor = %Actors.Agent{wallet_address: wallet("d"), chain_id: 8453, audience: "keyfleet"}

    assert Agents.check_in(actor, @fleet, %{"kind" => "session"}) == {:ok, nil}
    assert Agents.note_contribution(actor, @fleet, :post) == {:ok, nil}
  end

  describe "at the exact edges of an interval, on a database clock the test sets" do
    # `statement_timestamp()` resolves to a stand-in ahead of pg_catalog in
    # the search path, answering whatever time the test last set. The schema,
    # the setting and the search path all go with the test's transaction.
    setup do
      Repo.query!("CREATE SCHEMA test_clock")

      Repo.query!("""
      CREATE FUNCTION test_clock.statement_timestamp() RETURNS timestamptz
      LANGUAGE sql STABLE AS $$ SELECT current_setting('test_clock.now')::timestamptz $$
      """)

      Repo.query!("SET LOCAL search_path = test_clock, pg_catalog, keyfleet_app, public")
      clock!(0)
      :ok
    end

    test "a check-in just under half an interval after the counted one is too soon",
         %{actor: actor} do
      scheduled!(actor, 60)
      clock!(minutes(30) - 1)

      assert %{counted_scheduled_at: @t0, schedule_confirmed_at: nil} = scheduled!(actor, 60)
    end

    test "a check-in half an interval after the counted one confirms the schedule",
         %{actor: actor} do
      scheduled!(actor, 60)
      clock!(minutes(30))

      assert %{schedule_confirmed_at: confirmed, counted_scheduled_at: counted} =
               scheduled!(actor, 60)

      assert confirmed == at(minutes(30))
      assert counted == at(minutes(30))
    end

    test "half of an odd interval is measured to the second", %{actor: actor} do
      {other, _profile} = agent("c", "Able")
      scheduled!(actor, 15)
      scheduled!(other, 15)

      clock!(minutes(7) + seconds(29))
      assert %{schedule_confirmed_at: nil} = scheduled!(actor, 15)

      clock!(minutes(7) + seconds(30))
      assert %{schedule_confirmed_at: %DateTime{}} = scheduled!(other, 15)
    end

    test "a check-in the interval plus the grace after the counted one still confirms",
         %{actor: actor} do
      scheduled!(actor, 60)
      clock!(minutes(60 + CheckInStatus.grace_minutes()))

      assert %{schedule_confirmed_at: %DateTime{}} = scheduled!(actor, 60)
    end

    test "one second later it counts, and only the next on-time one confirms",
         %{actor: actor} do
      late = minutes(60 + CheckInStatus.grace_minutes()) + seconds(1)
      scheduled!(actor, 60)
      clock!(late)

      assert %{schedule_confirmed_at: nil, counted_scheduled_at: counted} = scheduled!(actor, 60)
      assert counted == at(late)

      clock!(late + minutes(60))
      assert %{schedule_confirmed_at: %DateTime{}} = scheduled!(actor, 60)
    end

    test "twice the interval plus the grace keeps a confirmation; one second more loses it",
         %{actor: actor} do
      gap = minutes(2 * 60 + CheckInStatus.grace_minutes())
      scheduled!(actor, 60)
      clock!(minutes(60))
      %{schedule_confirmed_at: confirmed} = scheduled!(actor, 60)

      clock!(minutes(60) + gap)
      assert %{schedule_confirmed_at: ^confirmed} = scheduled!(actor, 60)

      clock!(minutes(60) + 2 * gap + seconds(1))
      assert %{schedule_confirmed_at: nil} = scheduled!(actor, 60)
    end
  end

  defp confirm!(actor, minutes) do
    scheduled!(actor, minutes)
    minutes_pass!(minutes)
    %{schedule_confirmed_at: %DateTime{}} = scheduled!(actor, minutes)
  end

  defp scheduled!(actor, minutes) do
    {:ok, check_in} =
      Agents.check_in(actor, @fleet, %{"kind" => "scheduled", "every_minutes" => minutes})

    check_in
  end

  defp session!(actor) do
    {:ok, check_in} = Agents.check_in(actor, @fleet, %{"kind" => "session"})
    check_in
  end

  defp check_in(actor) do
    {:ok, profile} = Agents.get_my_profile(actor: actor)
    Agents.get_check_in!(profile.id, @fleet)
  end

  defp status(check_in), do: check_in |> CheckInStatus.derive(DateTime.utc_now()) |> elem(0)

  defp minutes_pass!(minutes), do: seconds_pass!(minutes * 60)

  # The stand-in database clock reads `microseconds` after @t0.
  defp clock!(microseconds),
    do:
      Repo.query!("SELECT set_config('test_clock.now', $1, true)", [
        DateTime.to_iso8601(at(microseconds))
      ])

  defp at(microseconds), do: DateTime.add(@t0, microseconds, :microsecond)
  defp seconds(count), do: count * 1_000_000
  defp minutes(count), do: seconds(count * 60)

  # Time passing, as far as the recorded check-ins can tell: every time on
  # them moves back.
  defp seconds_pass!(seconds) do
    Repo.query!(
      """
      UPDATE keyfleet_app.agent_check_ins SET
        last_check_in_at = last_check_in_at - make_interval(secs => $1),
        last_session_at = last_session_at - make_interval(secs => $1),
        last_scheduled_at = last_scheduled_at - make_interval(secs => $1),
        counted_scheduled_at = counted_scheduled_at - make_interval(secs => $1),
        schedule_confirmed_at = schedule_confirmed_at - make_interval(secs => $1),
        last_contribution_at = last_contribution_at - make_interval(secs => $1)
      """,
      [seconds]
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp agent(character, name) do
    actor = %Actors.Agent{wallet_address: wallet(character), chain_id: 8453, audience: "keyfleet"}

    profile =
      Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"}, actor: actor)

    {actor, profile}
  end
end
