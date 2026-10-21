defmodule Keyfleet.DirectoryTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Directory
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
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

  test "open work leaves out what is finished, dropped or archived" do
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
    finished = Workspace.create(@fleet, "task", %{"title" => "Finished", "progress" => "doing"})
    Workspace.submit(@fleet, finished, "https://example.com/finished")
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
             tasks_taken: 2,
             tasks_untaken: 3
           } = fleet.work

    assert goal |> Map.keys() |> Enum.sort() == [:changed_at, :id, :title]
    assert {:error, %Ash.Error.Invalid{}} = Graph.open_work(@fleet, :tasks_done)
  end

  test "a long post's excerpt ends at a word with an ellipsis, within 280 code points" do
    family = "👨‍👩‍👧"
    words = String.duplicate("word ", 60)
    writer = PairingHelpers.agent_for!(owner())
    post!(writer, "general", String.duplicate("a", 275) <> family <> "b")
    post!(writer, "general", String.duplicate("b", 279) <> family)
    post!(writer, "general", words)
    post!(writer, "general", String.duplicate("c", 280))

    {:ok, fleet} = Directory.fleet(@fleet)
    excerpts = Enum.map(fleet.recent_posts, & &1.excerpt)

    assert excerpts == [
             String.duplicate("c", 280),
             String.trim_trailing(String.duplicate("word ", 56)) <> "…",
             String.duplicate("b", 279) <> "…",
             String.duplicate("a", 275) <> "…"
           ]

    assert Enum.all?(excerpts, &(length(String.codepoints(&1)) <= 280))
  end

  test "latest posts are the newest ten in the fleet's rooms, never a key's thread" do
    writer = PairingHelpers.agent_for!(owner())
    for n <- 1..11, do: post!(writer, "general", "Post #{n}")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 2, body: "To key two", idempotency_key: "thread"},
      actor: owner()
    )

    {:ok, fleet} = Directory.fleet(@fleet)

    assert Enum.map(fleet.recent_posts, & &1.excerpt) == for(n <- 11..2//-1, do: "Post #{n}")

    assert hd(fleet.recent_posts).author == %{
             kind: :human,
             wallet: RegentFormat.short_address(@owner),
             via_agent: "Their agent"
           }

    assert fleet.last_post_at == hd(fleet.recent_posts).at

    assert listed(@fleet).last_post_at == fleet.last_post_at
  end

  test "a room's posts leave out the lines that record its namings" do
    writer = PairingHelpers.agent_for!(owner())

    "open-1"
    |> then(&Rooms.get_room!(@fleet, &1, authorize?: false))
    |> Rooms.set_room_topic!("Dry dock", actor: writer)

    post!(writer, "open-1", "First")
    post!(writer, "open-1", "Second")

    rooms = Rooms.list_rooms!(@fleet, authorize?: false, load: [:post_count])
    assert %{topic: "Dry dock", post_count: 2} = Enum.find(rooms, &(&1.slug == "open-1"))

    # The directory, read by anyone, lists the Public room alone.
    {:ok, fleet} = Directory.fleet(@fleet)
    assert [%{slug: "general", posts: 0}] = fleet.rooms
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

  defp owner, do: %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

  defp post!(writer, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: writer
    )
  end
end
