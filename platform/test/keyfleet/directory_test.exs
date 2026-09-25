defmodule Keyfleet.DirectoryTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Directory
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.KeeperHelpers
  alias Keyfleet.Keys
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
    Rooms.bootstrap_rooms!()
    KeeperHelpers.deploy!(@fleet, "0x" <> String.duplicate("7", 40), 8_453)
    ChainHelpers.seed_cursor!(@fleet)
    for token_id <- 1..6, do: epoch!(token_id, 0, @owner)
    :ok
  end

  test "only agents running one of the fleet's keys right now are here, each once by name" do
    two_keys = agent("b", "Bosun")
    attach!(two_keys, 2)
    attach!(two_keys, 1)
    attach!(agent("c", "Able"), 3)

    # Waiting for the owner, removed by the owner, and attached under the
    # key's owner before the one who holds it now.
    request!(agent("d", "Waiting"), 4)
    Keys.detach_operator!(attach!(agent("e", "Removed"), 5), %{}, actor: owner())
    attach!(agent("f", "Former"), 6)
    epoch!(6, 1, "0x" <> String.duplicate("9", 40))

    {:ok, fleet} = Directory.fleet(@fleet)

    assert fleet.agents_here == 2

    assert fleet.agents == [
             %{
               name: "Able",
               declared_harness: "Hermes Agent",
               wallet_address: wallet("c"),
               keys_run: 1,
               first_key: 3
             },
             %{
               name: "Bosun",
               declared_harness: "Hermes Agent",
               wallet_address: wallet("b"),
               keys_run: 2,
               first_key: 1
             }
           ]
  end

  test "open work leaves out what is finished, dropped, archived or already taken" do
    Workspace.open_log(@fleet)
    open = Workspace.create(@fleet, "goal", %{"title" => "Map the first paid service"})
    Workspace.create(@fleet, "goal", %{"title" => "Done", "status" => "achieved"})
    Workspace.create(@fleet, "goal", %{"title" => "Gave up", "status" => "dropped"})
    Workspace.archive(@fleet, Workspace.create(@fleet, "goal", %{"title" => "Archived"}))

    untaken = Workspace.create(@fleet, "task", %{"title" => "Nobody's"})
    Workspace.create(@fleet, "task", %{"title" => "Claimed", "assignee_key" => 12})

    doing =
      Workspace.create(@fleet, "task", %{
        "title" => "Underway",
        "progress" => "doing",
        "assignee_key" => 12,
        "next_step" => "Draft the price"
      })

    Workspace.create(@fleet, "task", %{"title" => "Finished", "progress" => "done"})
    Workspace.create(@fleet, "task", %{"title" => "Stuck", "progress" => "blocked"})

    Workspace.archive(
      @fleet,
      Workspace.create(@fleet, "task", %{"title" => "Old", "progress" => "doing"})
    )

    {:ok, fleet} = Directory.fleet(@fleet)

    assert {fleet.open_goals, fleet.tasks_in_progress} == {1, 1}
    assert Enum.map(fleet.work.open_goals, & &1.id) == [open]
    assert Enum.map(fleet.work.tasks_untaken, & &1.id) == [untaken]

    assert [%{id: ^doing, title: "Underway", gist: "Draft the price", assignee_key: 12}] =
             fleet.work.tasks_in_progress

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
    assert hd(fleet.recent_posts).author == %{kind: :human, wallet: @owner}
    assert fleet.last_post_at == hd(fleet.recent_posts).at

    [summary | _] = Directory.list()
    assert summary.last_post_at == fleet.last_post_at
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
             keys_total: 46_365,
             keys_left: 46_359,
             next_key: %{token_id: 7, price_atomic_usdc: 14_400_000, level: 3, holding_limit: 1}
           }

    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -1, :day))
    assert {:ok, %{sales: %{on_sale: true, current: false} = stale}} = Directory.fleet(@fleet)
    assert map_size(stale) == 2

    assert {:ok, %{sales: %{on_sale: false}}} = Directory.fleet("fleet_tech_classic")
    assert Directory.fleet("fleet_unknown") == :unknown
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

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  defp agent(character, name) do
    actor = %Actors.Agent{wallet_address: wallet(character), chain_id: 8453, audience: "keyfleet"}
    Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"}, actor: actor)
    actor
  end

  defp request!(actor, token_id), do: Keys.request_pairing!(@fleet, token_id, %{}, actor: actor)

  defp attach!(actor, token_id),
    do:
      actor |> request!(token_id) |> Keys.approve_pairing!(Keys.default_limits(), actor: owner())

  defp post!(slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: owner()
    )
  end
end
