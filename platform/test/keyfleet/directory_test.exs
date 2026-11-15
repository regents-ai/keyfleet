defmodule Keyfleet.DirectoryTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Directory
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    # A fleet's entry reads its workspace in a repeatable-read snapshot, which
    # Postgres allows inside the sandbox only at that level already.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    for token_id <- 1..6, do: epoch!(token_id, 1, wallet(token_id))
    :ok
  end

  test "a fleet's entry gives each project by title with its open goals' titles" do
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "lab", "Lab")
    Workspace.create(@fleet, "goal", %{"title" => "Map the first paid service"})
    Workspace.create(@fleet, "goal", %{"title" => "Done", "status" => "achieved"})
    Workspace.create(@fleet, "goal", %{"title" => "Try the new model"}, project: "lab")
    Workspace.create(@fleet, "task", %{"title" => "Draft the price"})

    {:ok, fleet} = Directory.fleet(@fleet)

    assert fleet.projects == [
             %{name: "general", title: "General", goals: ["Map the first paid service"]},
             %{name: "scratchpad", title: "Append-only scratchpad", goals: []},
             %{
               name: "understanding",
               title: "Keyfleet Syndicate #1 Collaborative Understanding",
               goals: []
             },
             %{name: "lab", title: "Lab", goals: ["Try the new model"]}
           ]
  end

  test "a long post's excerpt ends at a word with an ellipsis, within 280 code points" do
    family = "👨‍👩‍👧"
    words = String.duplicate("word ", 60)
    post!(writer(1), "general", String.duplicate("a", 275) <> family <> "b")
    post!(writer(2), "general", String.duplicate("b", 279) <> family)
    post!(writer(3), "general", words)
    post!(writer(4), "general", String.duplicate("c", 280))

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

  test "one Key's flood of posts leaves it one line, and the other Keys' newest posts still show" do
    post!(writer(2), "general", "Two, first")
    post!(writer(3), "general", "Three")
    post!(writer(2), "general", "Two, again")
    for n <- 1..12, do: post!(writer(1), "general", "Flood #{n}")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 2, body: "To key two", idempotency_key: "thread"},
      actor: holder(1)
    )

    {:ok, fleet} = Directory.fleet(@fleet)

    assert Enum.map(fleet.recent_posts, &{&1.as_key, &1.excerpt}) == [
             {1, "Flood 12"},
             {2, "Two, again"},
             {3, "Three"}
           ]

    assert hd(fleet.recent_posts).author == %{
             kind: :human,
             wallet: RegentFormat.short_address(wallet(1)),
             via_agent: "Their agent"
           }

    assert fleet.last_post_at == hd(fleet.recent_posts).at
    assert listed(@fleet).last_post_at == fleet.last_post_at
  end

  test "a post written as no Key counts the wallet that wrote it as its writer" do
    visitor = keyless("b")
    other = keyless("c")
    post!(visitor, "people", "Hello")
    post!(other, "people", "Hi there")
    post!(visitor, "people", "Hello again")

    {:ok, fleet} = Directory.fleet(@fleet)

    assert Enum.map(fleet.recent_posts, &{&1.as_key, &1.excerpt}) == [
             {nil, "Hello again"},
             {nil, "Hi there"}
           ]
  end

  test "the day's posts count the last 24 hours in the rooms anyone reads, never a Key's thread" do
    post!(writer(1), "general", "Today")
    post!(keyless("b"), "people", "Hello")
    post!(writer(2), "open-1", "For members")
    post!(writer(3), "general", "Old")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 2, body: "To key two", idempotency_key: "thread"},
      actor: holder(1)
    )

    # Posts are never edited, so the old one is moved back two days with its
    # guard off, inside this test's own transaction.
    Repo.query!("ALTER TABLE keyfleet_app.messages DISABLE TRIGGER immutable_messages")

    Repo.query!(
      "UPDATE keyfleet_app.messages SET inserted_at = inserted_at - interval '2 days' WHERE body = 'Old'"
    )

    Repo.query!("ALTER TABLE keyfleet_app.messages ENABLE TRIGGER immutable_messages")

    {:ok, fleet} = Directory.fleet(@fleet)

    assert fleet.posts_last_day == 2
    assert Enum.map(fleet.recent_posts, & &1.excerpt) == ["Hello", "Today", "Old"]
  end

  test "a room's posts leave out the lines that record its namings" do
    writer = writer(1)

    "open-1"
    |> then(&Rooms.get_room!(@fleet, &1, authorize?: false))
    |> Rooms.set_room_topic!("Dry dock", actor: writer)

    post!(writer, "open-1", "First")
    post!(writer, "open-1", "Second")

    rooms = Rooms.list_rooms!(@fleet, authorize?: false, load: [:post_count])
    assert %{topic: "Dry dock", post_count: 2} = Enum.find(rooms, &(&1.slug == "open-1"))

    # The directory, read by anyone, lists the rooms anyone reads alone.
    {:ok, fleet} = Directory.fleet(@fleet)
    assert [%{slug: "general", posts: 0}, %{slug: "people", posts: 0}] = fleet.rooms
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

  # Each Key has a holder of its own.
  defp wallet(token_id), do: "0x" <> String.duplicate("#{token_id}", 40)

  defp holder(token_id),
    do: %Actors.Human{human_account_id: token_id, wallet_addresses: [wallet(token_id)]}

  # The agent of Key `token_id`'s holder, which writes as that Key for them.
  defp writer(token_id), do: PairingHelpers.agent_for!(holder(token_id))

  # An agent whose person holds no Key, which writes as no Key from its own
  # wallet, in the People and agents room.
  defp keyless(character) do
    agent = PairingHelpers.pair_wallet!("0x" <> String.duplicate(character, 40))
    Agents.ensure_profile!(%{name: "Visitor", declared_harness: "test"}, actor: agent)
    agent
  end

  defp post!(writer, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: writer
    )
  end
end
