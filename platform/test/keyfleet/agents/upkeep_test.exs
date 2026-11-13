defmodule Keyfleet.Agents.UpkeepTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [keys_sold!: 3, presence!: 3, scheduled!: 3]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
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

  # The person holds Keys 1 and 2, on the account `PairingHelpers.pair!/2`
  # pairs their agent with, and their agent holds a shard of each.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    keys_sold!(@fleet, [1, 2], @person)

    did = "did:privy:test-" <> @person
    account = Accounts.register_verified!(did, @person, [@person], actor: %Actors.System{})
    agent = pair!()
    for token_id <- [1, 2], do: ChainHelpers.issue_shard!(@fleet, token_id, @agent)
    %{person: Actors.Human.for_account(account), agent: agent}
  end

  test "an agent's Keys need no mark while present or waiting for their automatic start",
       %{person: person} do
    presence!(@fleet, 1, DateTime.utc_now(:second))
    scheduled!(@fleet, 2, DateTime.add(DateTime.utc_now(:second), 3_600))

    assert [%{key_count: 2, marked: true}] = Upkeep.person_agents(person, @fleet)
  end

  test "a Key whose 48 hours ended, or whose presence was cleared, needs a mark again",
       %{person: person} do
    presence!(@fleet, 1, DateTime.add(DateTime.utc_now(:second), -3, :day))
    presence!(@fleet, 2, DateTime.utc_now(:second))
    assert [%{marked: false}] = Upkeep.person_agents(person, @fleet)

    presence!(@fleet, 1, DateTime.utc_now(:second))
    presence!(@fleet, 2, nil)
    assert [%{marked: false}] = Upkeep.person_agents(person, @fleet)
  end

  # Money nobody has moved is the agents' to move, never an error the site saves.
  test "money waiting too long reaches the agent's check-in, oldest first, and saves no error",
       %{agent: agent} do
    errors = saved_errors()
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
