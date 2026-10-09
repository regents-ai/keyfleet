defmodule Keyfleet.DirectoryTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Directory
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.PublicIdentity
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}
  @owner "0x" <> String.duplicate("a", 40)

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    for token_id <- 1..6, do: epoch!(token_id, 1, @owner)
    :ok
  end

  test "the agents here hold a key, an active shard of one, or are paired with a person who does" do
    # Bosun's shard is renewed, and counts once. Keeper's own wallet holds
    # key 2. Mate is backed by a World ID person, paired with them, whose
    # account names the owner's wallet in capitals.
    attach!(agent("b", "Bosun"), 1)
    attach!(agent("b", "Bosun"), 1)
    attach!(agent("c", "Able"), 3)
    epoch!(2, 2, wallet("7"))
    agent("7", "Keeper")
    pair!(agent("8", "Mate", backed: true), String.upcase(@owner))

    # A wallet with no shard, a shard its owner ended, one that ran out, one
    # issued under the key's owner before the one who holds it now, and an
    # agent paired with the owner but backed by nobody.
    agent("d", "Waiting")
    attach!(agent("e", "Removed"), 5)
    ChainHelpers.end_shard!(@fleet, 5, wallet("e"), @owner)
    agent("9", "Expired")
    ChainHelpers.issue_shard!(@fleet, 4, wallet("9"), -1)
    attach!(agent("f", "Former"), 6)
    epoch!(6, 2, wallet("6"))
    pair!(agent("5", "Unbacked"), @owner)

    {:ok, fleet} = Directory.fleet(@fleet)

    assert fleet.agents_here == 4
    assert listed(@fleet).agents_here == 4

    never = %{
      status: :never_checked_in,
      status_label: "Hasn’t checked in",
      last_check_in_at: nil,
      schedule_minutes: nil,
      last_contribution_at: nil,
      last_contribution: nil
    }

    assert fleet.agents ==
             for(
               {character, name, key} <- [
                 {"c", "Able", 3},
                 {"b", "Bosun", 1},
                 {"7", "Keeper", 2},
                 {"8", "Mate", 1}
               ],
               do:
                 Map.merge(never, %{
                   name: name,
                   avatar_src: PublicIdentity.avatar_src(%{wallet_address: wallet(character)}),
                   declared_harness: "Hermes Agent",
                   wallet_address: wallet(character),
                   key: key
                 })
             )
  end

  test "the agents who checked in most recently come first, then the rest by name" do
    for {character, name, token_id} <- [{"b", "Bosun", 1}, {"c", "Able", 2}, {"d", "Cook", 3}],
        do: attach!(agent(character, name), token_id)

    # Cook checked in on its schedule two days ago; Bosun is in a
    # conversation now; Able never checked in.
    {:ok, _cook} =
      Agents.check_in(actor("d"), @fleet, %{"kind" => "scheduled", "every_minutes" => 60})

    Repo.query!("""
    UPDATE keyfleet_app.agent_check_ins SET
      last_check_in_at = last_check_in_at - interval '2 days',
      last_scheduled_at = last_scheduled_at - interval '2 days',
      counted_scheduled_at = counted_scheduled_at - interval '2 days'
    """)

    {:ok, _bosun} = Agents.check_in(actor("b"), @fleet, %{"kind" => "session"})
    {:ok, fleet} = Directory.fleet(@fleet)

    assert Enum.map(fleet.agents, &{&1.name, &1.status, &1.schedule_minutes}) == [
             {"Bosun", :connected_now, nil},
             {"Cook", :paused, 60},
             {"Able", :never_checked_in, nil}
           ]

    assert fleet.agents_checked_in_last_day == 1
    assert listed(@fleet).agents_checked_in_last_day == 1
  end

  test "open work leaves out what is finished, dropped, archived or already taken" do
    Workspace.open_log(@fleet)
    open = Workspace.create(@fleet, "goal", %{"title" => "Map the first paid service"})
    Workspace.create(@fleet, "goal", %{"title" => "Done", "status" => "achieved"})
    Workspace.create(@fleet, "goal", %{"title" => "Gave up", "status" => "dropped"})
    Workspace.archive(@fleet, Workspace.create(@fleet, "goal", %{"title" => "Archived"}))

    Workspace.create(@fleet, "task", %{"title" => "Nobody's"})
    Workspace.create(@fleet, "task", %{"title" => "Claimed", "assignee_key" => 12})

    Workspace.create(@fleet, "task", %{
      "title" => "Underway",
      "progress" => "doing",
      "assignee_key" => 12
    })

    Workspace.create(@fleet, "task", %{"title" => "Nobody on it", "progress" => "doing"})
    Workspace.create(@fleet, "task", %{"title" => "Finished", "progress" => "done"})
    Workspace.create(@fleet, "task", %{"title" => "Stuck", "progress" => "blocked"})

    Workspace.archive(
      @fleet,
      Workspace.create(@fleet, "task", %{"title" => "Old", "progress" => "doing"})
    )

    {:ok, fleet} = Directory.fleet(@fleet)

    assert {fleet.open_goals, fleet.tasks_in_progress} == {1, 2}

    # The goals by title, and how much work there is; never the work itself.
    assert %{
             open_goals: [%{id: ^open, title: "Map the first paid service"} = goal],
             tasks_taken: 1,
             tasks_untaken: 1
           } = fleet.work

    assert goal |> Map.keys() |> Enum.sort() == [:changed_at, :id, :title]
    assert {:error, %Ash.Error.Invalid{}} = Graph.open_work(@fleet, :tasks_done)
  end

  test "latest posts are the newest ten in the fleet's rooms, never a key's thread" do
    for n <- 1..11, do: post!("general", "Post #{n}")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 2, body: "To key two", idempotency_key: "thread"},
      actor: owner()
    )

    {:ok, fleet} = Directory.fleet(@fleet)

    assert Enum.map(fleet.recent_posts, & &1.excerpt) == for(n <- 11..2//-1, do: "Post #{n}")
    assert hd(fleet.recent_posts).author == %{kind: :human, wallet: @owner, via_agent: nil}
    assert fleet.last_post_at == hd(fleet.recent_posts).at

    assert listed(@fleet).last_post_at == fleet.last_post_at
  end

  test "a room's posts leave out the lines that record its namings" do
    "open-1"
    |> then(&Rooms.get_room!(@fleet, &1))
    |> Rooms.set_room_topic!("Dry dock", actor: owner())

    post!("open-1", "First")
    post!("open-1", "Second")

    {:ok, fleet} = Directory.fleet(@fleet)

    assert %{name: "Dry dock", posts: 2} = Enum.find(fleet.rooms, &(&1.slug == "open-1"))
    assert %{posts: 0} = Enum.find(fleet.rooms, &(&1.slug == "general"))
  end

  test "a fleet whose sales are still being read shows no price" do
    assert {:ok, %{sales: sales}} = Directory.fleet(@fleet)

    assert sales == %{
             on_sale: true,
             current: true,
             keys_sold: 6,
             keys_total: nil,
             keys_left: nil,
             next_key: %{token_id: 7, price_atomic_usdc: 14_400_000, level: 3}
           }

    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -1, :day))
    assert {:ok, %{sales: %{on_sale: true, current: false} = stale}} = Directory.fleet(@fleet)
    assert map_size(stale) == 2

    assert {:ok, %{coming_soon: true}} = Directory.fleet("fleet_tech_classic")
    assert Directory.fleet("fleet_unknown") == :unknown
  end

  # Every fleet opens once its deployment is recorded, as this fleet's was
  # in the setup.
  test "a fleet coming soon gives its name and nothing else, until its deployment is recorded" do
    soon = %{id: "fibonacci_cascade", name: "Cascade #1", coming_soon: true}

    assert Directory.fleet("fibonacci_cascade") == {:ok, soon}

    assert {:ok, fleets} = Directory.list()

    assert Enum.map(fleets, &{&1.id, &1.coming_soon}) == [
             {"fleet_tech_classic", true},
             {@fleet, false},
             {"fibonacci_cascade", true},
             {"fleet_tech_accelerant", true},
             {"regents_club", true}
           ]

    assert listed("fibonacci_cascade") == soon
  end

  defp epoch!(token_id, epoch, owner_wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner_wallet,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("#{rem(token_id, 10)}", 63) <> "#{epoch}",
        log_index: token_id
      },
      actor: @system
    )
  end

  defp listed(fleet_id) do
    {:ok, fleets} = Directory.list()
    Enum.find(fleets, &(&1.id == fleet_id))
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  defp actor(character),
    do: %Actors.Agent{
      wallet_address: wallet(character),
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

  defp agent(character, name, opts \\ []) do
    actor =
      if opts[:backed],
        do: %{
          actor(character)
          | human_id: "0x" <> String.duplicate("1", 64),
            same_person_agent_count: 1
        },
        else: actor(character)

    Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"}, actor: actor)
    actor
  end

  # Pairs the agent with a person whose account here names `person_wallet`.
  defp pair!(actor, person_wallet) do
    did = "did:privy:directory:#{System.unique_integer([:positive])}"
    Accounts.register_verified!(did, person_wallet, [person_wallet], actor: @system)

    Repo.query!(
      """
      INSERT INTO regent_agents.paired_agents
        (privy_user_id, wallet, name, harness, paired_at, last_contact_at)
      VALUES ($1, $2, 'Probe', 'Hermes Agent', now(), now())
      """,
      [did, actor.wallet_address]
    )
  end

  defp attach!(actor, token_id),
    do: ChainHelpers.issue_shard!(@fleet, token_id, actor.wallet_address)

  defp post!(slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: owner()
    )
  end
end
