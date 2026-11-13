defmodule Keyfleet.Agents.UpkeepTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [keys_sold!: 3, presence!: 3, scheduled!: 3, wallet: 1]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Upkeep
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.PairingHelpers
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Treasury

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @person "0x" <> String.duplicate("a", 40)
  @agent "0x" <> String.duplicate("c", 40)
  @window 172_800

  # The person holds Keys 1 and 2, on the account `PairingHelpers.pair!/2`
  # pairs their agent with, and has no agent yet.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    keys_sold!(@fleet, [1, 2], @person)

    did = "did:privy:test-" <> @person
    account = Accounts.register_verified!(did, @person, [@person], actor: %Actors.System{})
    %{person: Actors.Human.for_account(account)}
  end

  test "is nil for someone who holds none of the fleet's Keys" do
    stranger = %Actors.Human{human_account_id: 1, wallet_addresses: [wallet("b")]}

    assert Upkeep.person_setup(stranger, @fleet) == nil
  end

  test "ticks each step off once the records show it", %{person: person} do
    assert %{keys: keys, agents: [], done: done} = Upkeep.person_setup(person, @fleet)
    assert keys == [%{token_id: 1, from: nil, until: nil}, %{token_id: 2, from: nil, until: nil}]
    assert done == %{pair: false, shard: false, run: false, present: false}

    agent = pair!()
    assert done(person) == %{pair: true, shard: false, run: false, present: false}

    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    assert done(person) == %{pair: true, shard: true, run: false, present: false}

    Agents.ensure_profile!(%{name: "Bosun", declared_harness: "Hermes Agent"}, actor: agent)

    {:ok, _check_in} =
      Agents.check_in(agent, @fleet, %{"kind" => "scheduled", "every_minutes" => 1440})

    assert done(person) == %{pair: true, shard: true, run: true, present: false}

    # Every Key the person holds needs no mark, not only the one the agent
    # holds a shard of.
    now = DateTime.utc_now(:second)
    presence!(@fleet, 1, now)
    assert done(person).present == false

    presence!(@fleet, 2, now)
    assert done(person) == %{pair: true, shard: true, run: true, present: true}

    assert %{keys: [%{token_id: 1, from: ^now, until: until}, _key_2]} =
             Upkeep.person_setup(person, @fleet)

    assert until == DateTime.add(now, @window)
  end

  # One reading for both: the Present step and the agent's Marked state.
  test "a Key waiting for its automatic start needs no mark, for the step and the agent alike",
       %{person: person} do
    pair!()
    for token_id <- [1, 2], do: ChainHelpers.issue_shard!(@fleet, token_id, @agent)
    starts = DateTime.add(DateTime.utc_now(:second), 3_600)
    presence!(@fleet, 1, DateTime.utc_now(:second))
    scheduled!(@fleet, 2, starts)

    assert %{keys: [_key_1, waiting], agents: [agent], done: %{present: true}} =
             Upkeep.person_setup(person, @fleet)

    assert waiting == %{token_id: 2, from: starts, until: DateTime.add(starts, @window)}
    assert agent.marked
  end

  test "a Key whose 48 hours ended, or whose presence was cleared, needs a mark again",
       %{person: person} do
    pair!()
    for token_id <- [1, 2], do: ChainHelpers.issue_shard!(@fleet, token_id, @agent)
    presence!(@fleet, 1, DateTime.add(DateTime.utc_now(:second), -3, :day))
    presence!(@fleet, 2, DateTime.utc_now(:second))

    assert %{done: %{present: false}, agents: [%{marked: false}]} =
             Upkeep.person_setup(person, @fleet)

    presence!(@fleet, 1, DateTime.utc_now(:second))
    presence!(@fleet, 2, nil)

    assert %{
             keys: [_key_1, %{token_id: 2, from: nil, until: nil}],
             done: %{present: false},
             agents: [%{marked: false}]
           } = Upkeep.person_setup(person, @fleet)
  end

  # Money nobody has moved is the agents' to move, never an error the site saves.
  test "money waiting too long reaches the agent's check-in, oldest first, and saves no error" do
    errors = saved_errors()
    agent = pair!()
    assert Upkeep.read(agent, @fleet, false).money_waiting == []

    now = DateTime.utc_now()
    ago = &DateTime.add(now, -&1, :hour)

    ProposalHelpers.treasury_reading!(
      @fleet,
      [%{asset: Treasury.native(), held: 10 ** 18, backed: 0}],
      block_time: now,
      next_run_at: DateTime.truncate(ago.(7), :second),
      protocol_share_owed: Decimal.new(1),
      protocol_share_owed_since: ago.(25),
      conversion_waiting: Decimal.new(1),
      conversion_waiting_since: ago.(4)
    )

    assert Upkeep.read(agent, @fleet, false).money_waiting == [
             %{step: :send_share, since: ago.(25)},
             %{step: :split, since: DateTime.truncate(ago.(7), :second)},
             %{step: :convert, since: ago.(4)}
           ]

    assert saved_errors() == errors
  end

  # Errors other suites left saved are counted before and set aside.
  defp saved_errors, do: Repo.aggregate(ErrorTracker.Occurrence, :count)

  defp done(person), do: Upkeep.person_setup(person, @fleet).done

  # The agent on `@agent`, paired with the person.
  defp pair! do
    PairingHelpers.pair!(
      %Actors.Agent{
        wallet_address: @agent,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      },
      [@person]
    )
  end
end
