defmodule Keyfleet.CheckInsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckIn
  alias Keyfleet.Fleets
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo

  @fleet "fleet_tech_classic"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    {actor, profile} = agent("b", "Bosun")
    %{actor: actor, profile: profile}
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

  # How many times an agent came back on its own is the proof its scheduler
  # works; a conversation's check-ins and a repeat within the minute are not.
  test "each scheduled check-in counts once, and a conversation's does not", %{
    actor: actor,
    profile: profile
  } do
    scheduled = %{"kind" => "scheduled", "every_minutes" => 30}

    assert {:ok, %{scheduled_check_ins: 1}} = Agents.check_in(actor, @fleet, scheduled)
    assert {:ok, %{scheduled_check_ins: 1}} = Agents.check_in(actor, @fleet, scheduled)

    assert {:ok, %{scheduled_check_ins: 1}} =
             Agents.check_in(actor, @fleet, %{"kind" => "session"})

    earlier!(30)

    assert {:ok, %{scheduled_check_ins: 2}} = Agents.check_in(actor, @fleet, scheduled)
    assert Agents.get_check_in!(profile.id, @fleet).scheduled_check_ins == 2
  end

  # Checking in more often than its schedule, or naming a new interval each
  # time, is still one return per step of the schedule.
  test "a scheduled check-in that comes too soon is not a return", %{actor: actor} do
    assert {:ok, %{scheduled_check_ins: 1}} =
             Agents.check_in(actor, @fleet, %{"kind" => "scheduled", "every_minutes" => 30})

    earlier!(2)

    assert {:ok, %{scheduled_check_ins: 1}} =
             Agents.check_in(actor, @fleet, %{"kind" => "scheduled", "every_minutes" => 30})

    earlier!(2)

    assert {:ok, %{scheduled_check_ins: 1}} =
             Agents.check_in(actor, @fleet, %{"kind" => "scheduled", "every_minutes" => 10})
  end

  # A daily run's check-in reaches every page its person has open, where
  # their agents' states read again, and is heard on no one else's. A repeat too soon to be written,
  # and a conversation's check-in, tell nobody.
  test "a scheduled check-in tells its own person's pages and no one else's", %{actor: actor} do
    {other, _profile} = agent("c", "Able")
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, RegentAgents.topic(actor.privy_user_id))
    other_page = open_page(other.privy_user_id)
    scheduled = %{"kind" => "scheduled", "every_minutes" => 1440}

    assert {:ok, _check_in} = Agents.check_in(actor, @fleet, scheduled)
    assert_received :agents_changed

    assert {:ok, _check_in} = Agents.check_in(actor, @fleet, scheduled)
    assert {:ok, _check_in} = Agents.check_in(actor, @fleet, %{"kind" => "session"})
    refute_received :agents_changed

    send(other_page, {:heard, self()})
    assert_receive {:heard, []}
  end

  # The account menu and the Agents page show each agent's best light across
  # its fleets; an agent that never came to Keyfleet has none.
  test "each agent's check-in light is its best across fleets", %{actor: actor, profile: profile} do
    {_able, _profile} = agent("c", "Able")

    for fleet <- [@fleet, "fibonacci_syndicate"] do
      CheckIn
      |> Ash.Changeset.for_create(
        :check_in_session,
        %{agent_profile_id: profile.id, fleet_id: fleet},
        actor: actor
      )
      |> Ash.create!()
    end

    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_session_at = last_session_at - interval '1 day' WHERE fleet_id = $1",
      [@fleet]
    )

    assert Agents.check_in_lights([wallet("b"), wallet("c"), wallet("d")], DateTime.utc_now()) ==
             %{
               wallet("b") => %{light: "on", light_label: "Connected now"},
               wallet("c") => %{light: "off", light_label: "Hasn’t checked in"},
               wallet("d") => %{light: nil, light_label: nil}
             }
  end

  # What an agent says blocks it is for itself and its person: not another
  # person, not another agent of the same person, not that person's Keyfleet
  # account, and not a read with no one signed in, nor one through the agent's
  # profile.
  test "what an agent says blocks it reaches its person and nobody else" do
    person_wallet = person_wallet()
    {actor, profile} = agent("e", "Echo", person_wallet)
    {sibling, _profile} = agent("f", "Fox", person_wallet)
    {other, _profile} = agent("c", "Able")
    line = "Waiting for my person to send gas on Base"
    blocked = %{"kind" => "session", "blocker" => line}

    assert {:ok, %{blocker: ^line}} = Agents.check_in(actor, @fleet, blocked)

    person = %RegentAgents.Person{privy_user_id: actor.privy_user_id}

    assert [%{blocker: ^line, fleet_id: @fleet}] =
             Agents.blocked_check_ins!([actor.wallet_address], actor: person)

    assert Agents.blocked_check_ins!([actor.wallet_address],
             actor: %RegentAgents.Person{privy_user_id: other.privy_user_id}
           ) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Agents.blocked_check_ins([actor.wallet_address], actor: actor)

    account = %Actors.Human{human_account_id: actor.human_account_id}

    for reader <- [other, sibling, account, nil] do
      assert %Ash.ForbiddenField{} =
               Agents.get_check_in!(profile.id, @fleet, actor: reader).blocker
    end

    assert Agents.get_check_in!(profile.id, @fleet, actor: actor).blocker == line
    assert Agents.get_check_in!(profile.id, @fleet, actor: person).blocker == line

    assert [%{check_ins: [%{blocker: %Ash.ForbiddenField{}}]}] =
             Agents.agents_by_wallets!([actor.wallet_address], load: [:check_ins])
  end

  # The line lasts until the agent's next check-in that is written, of
  # either kind; one too soon to be written keeps it.
  test "a check-in without a blocker clears it, one too soon keeps it", %{
    actor: actor,
    profile: profile
  } do
    scheduled = %{"kind" => "scheduled", "every_minutes" => 30}

    assert {:ok, %{blocker: "Stuck"}} =
             Agents.check_in(actor, @fleet, Map.put(scheduled, "blocker", "Stuck"))

    assert {:ok, %{blocker: "Stuck"}} = Agents.check_in(actor, @fleet, scheduled)

    earlier!(30)
    assert {:ok, %{blocker: nil}} = Agents.check_in(actor, @fleet, scheduled)

    assert {:ok, %{blocker: "Still stuck"}} =
             Agents.check_in(actor, @fleet, %{"kind" => "session", "blocker" => "Still stuck"})

    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_session_at = last_session_at - interval '2 minutes'"
    )

    assert {:ok, %{blocker: nil}} = Agents.check_in(actor, @fleet, %{"kind" => "session"})
    assert Agents.get_check_in!(profile.id, @fleet, actor: actor).blocker == nil
  end

  # One line of plain text, up to 280 characters once trimmed: an empty one is
  # none, and one too long or holding a control character, an invisible one or
  # a line break is refused and changes nothing.
  test "a blocker is trimmed, an empty one is none, and a bad one is refused", %{
    actor: actor,
    profile: profile
  } do
    session = fn line -> %{"kind" => "session", "blocker" => line} end

    assert {:ok, %{blocker: "Waiting on review"}} =
             Agents.check_in(actor, @fleet, session.("  Waiting on review \n"))

    for line <- [
          String.duplicate("a", 281),
          "Waiting\non review",
          "Waiting on\u0007 review",
          "Waiting​ on review"
        ] do
      assert {:error, %Ash.Error.Invalid{}} = Agents.check_in(actor, @fleet, session.(line))
      refute CheckIn.blocker?(line)
    end

    assert Agents.get_check_in!(profile.id, @fleet, actor: actor).blocker == "Waiting on review"

    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_session_at = last_session_at - interval '2 minutes'"
    )

    long = String.duplicate("é", 280)
    assert CheckIn.blocker?(long)
    assert {:ok, %{blocker: ^long}} = Agents.check_in(actor, @fleet, session.(" #{long} "))

    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_session_at = last_session_at - interval '2 minutes'"
    )

    assert {:ok, %{blocker: nil}} = Agents.check_in(actor, @fleet, session.("   "))
  end

  # As if the last scheduled check-in came `minutes` earlier.
  defp earlier!(minutes) do
    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_scheduled_at = last_scheduled_at - make_interval(mins => $1), counted_scheduled_at = counted_scheduled_at - make_interval(mins => $1)",
      [minutes]
    )
  end

  # A page of `person`'s open in a process of its own, which says what it
  # heard when asked. It answers after anything it heard before the asking.
  defp open_page(person) do
    test = self()

    page =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Keyfleet.PubSub, RegentAgents.topic(person))
        send(test, :page_open)
        hear([])
      end)

    assert_receive :page_open
    page
  end

  defp hear(heard) do
    receive do
      {:heard, test} -> send(test, {:heard, Enum.reverse(heard)})
      message -> hear([message | heard])
    end
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp person_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp agent(character, name, person_wallet \\ person_wallet()) do
    actor =
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: wallet(character),
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [person_wallet]
      )

    profile =
      Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"}, actor: actor)

    {actor, profile}
  end
end
