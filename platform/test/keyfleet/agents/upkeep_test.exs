defmodule Keyfleet.Agents.UpkeepTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [keys_sold!: 3, presence!: 3, scheduled!: 3]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents.Upkeep
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo

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
    pair!()
    for token_id <- [1, 2], do: ChainHelpers.issue_shard!(@fleet, token_id, @agent)
    %{person: Actors.Human.for_account(account)}
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
