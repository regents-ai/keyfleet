defmodule KeyFleet.LevelRoomsTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Repo
  alias KeyFleet.Rooms
  alias KeyFleet.Rooms.Errors.RoomUnknownError
  alias KeyFleet.Rooms.Errors.TopicRoomLimitError
  alias KeyFleet.Rooms.Room

  # Syndicate keys other suites commit outside the sandbox would count as
  # sold, so the levels are read on the Cascade fleet.
  @levelled "fibonacci_cascade"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    Enum.each(Fleets.catalog_ids(), &ChainHelpers.seed_cursor!/1)
    Rooms.bootstrap_core_rooms!()
    :ok
  end

  describe "level rooms" do
    test "a level's room opens once its first key is on record as sold, and not before" do
      assert level_rooms(@levelled) == []

      record(@levelled, 1)
      assert level_rooms(@levelled) == []
      :ok = Rooms.ensure_level_rooms(@levelled)
      assert level_rooms(@levelled) == [{"level-1", "Level 1", 1}]

      sell(@levelled, 1)
      assert level_rooms(@levelled) == [{"level-1", "Level 1", 1}]

      # The rest of level 1 opens nothing new; level 2's first key opens its room.
      sell(@levelled, 2)
      assert level_rooms(@levelled) == [{"level-1", "Level 1", 1}]

      sell(@levelled, 3)
      assert level_rooms(@levelled) == [{"level-1", "Level 1", 1}, {"level-2", "Level 2", 2}]

      sell(@levelled, 4..5)
      assert length(level_rooms(@levelled)) == 2

      sell(@levelled, 6)
      assert Enum.map(level_rooms(@levelled), &elem(&1, 0)) == ~w(level-1 level-2 level-3)
    end

    # Recording who owns a key never waits on, or fails with, a room.
    test "recording a sale or a key changing hands writes nothing to the rooms" do
      assert room_writes_during(fn ->
               record(@levelled, 1..6)
               record(@levelled, 1..6)
               transfer(@levelled, 3)
             end) == []

      assert level_rooms(@levelled) == []
    end

    # Posting moves a room's row, so opening rooms again must not write to,
    # or lock, one already open: its row stays the very same version.
    test "opening the rooms again leaves every open room's row untouched" do
      sell(@levelled, 1..3)
      before = room_versions(@levelled)

      transfer(@levelled, 3)
      :ok = Rooms.ensure_level_rooms(@levelled)
      :ok = Rooms.ensure_level_rooms(@levelled)
      Rooms.bootstrap_level_rooms!()

      assert room_versions(@levelled) == before
    end

    test "a sale recorded out of order still opens every level below it" do
      sell(@levelled, 11)
      assert Enum.map(level_rooms(@levelled), &elem(&1, 2)) == [1, 2, 3, 4]
    end

    test "setup opens the rooms of levels already sold, in each Fibonacci fleet only" do
      record(@levelled, 1..6)
      record("fleet_tech_classic", 1..6)
      record("fleet_tech_accelerant", 1..6)
      assert level_rooms(@levelled) == []

      :ok = Rooms.bootstrap_level_rooms!()
      assert Enum.map(level_rooms(@levelled), &elem(&1, 2)) == [1, 2, 3]
      first = room_versions(@levelled)

      :ok = Rooms.bootstrap_level_rooms!()
      assert room_versions(@levelled) == first

      for fleet <- ~w(fleet_tech_classic fleet_tech_accelerant) do
        assert level_rooms(fleet) == []
      end

      # Every level room the Syndicate has matches its sales, whatever other
      # suites have committed there.
      {:ok, minted} = KeyFleet.Chain.minted("fibonacci_syndicate")

      assert length(level_rooms("fibonacci_syndicate")) ==
               Fleets.Presets.active_levels(minted)
    end

    test "Classic and Accelerant sales open no level rooms" do
      for fleet <- ~w(fleet_tech_classic fleet_tech_accelerant) do
        sell(fleet, 1..12)
        assert level_rooms(fleet) == []
        assert Enum.map(Rooms.list_rooms!(fleet), & &1.slug) == ~w(general planning work)
      end
    end

    test "a fleet lists its core rooms, then its levels in order, then its topics" do
      sell(@levelled, 231)
      member = owner(231)

      Rooms.create_topic_room!(
        %{fleet_id: @levelled, slug: "anchor", name: "Anchor", level: 10},
        actor: member
      )

      Rooms.create_topic_room!(%{fleet_id: @levelled, slug: "bridge", name: "Bridge"},
        actor: member
      )

      # Topics for the whole fleet come before topics that follow a level.
      assert Enum.map(Rooms.list_rooms!(@levelled), & &1.slug) ==
               ~w(general planning work) ++
                 Enum.map(1..10, &"level-#{&1}") ++ ~w(bridge anchor)
    end

    test "nobody but the system opens a level's room, and no room is ever renamed" do
      sell(@levelled, 1..3)

      assert Enum.map(Ash.Resource.Info.actions(Room), &{&1.type, &1.name}) --
               [{:read, :for_fleet}, {:read, :in_fleet}] ==
               [{:create, :bootstrap}, {:create, :create_topic}]

      for actor <- [owner(1), agent("c"), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.create(Room, %{fleet_id: @levelled, slug: "general", name: "Level 3"},
                   action: :bootstrap,
                   actor: actor
                 )
      end

      for slug <- ~w(level-3 level-1 level-99 level-03 general planning work) do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :slug}]}} =
                 Rooms.create_topic_room(
                   %{fleet_id: @levelled, slug: slug, name: "Mine now"},
                   actor: owner(1)
                 ),
               slug
      end

      assert Enum.map(level_rooms(@levelled), &elem(&1, 0)) == ~w(level-1 level-2)
    end

    test "the database keeps each level to one room named after it" do
      sell(@levelled, 1)

      for {kind, slug, level} <- [
            {"level", "level-2", 3},
            {"level", "second", 2},
            {"core", "level-2", nil},
            {"topic", "level-2", nil},
            {"core", "lounge", 2},
            {"topic", "lounge", 21}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(
                   "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind, level) " <>
                     "VALUES ($1, $2, $3, 'Unwanted', $4, $5)",
                   [Ecto.UUID.dump!(Ash.UUID.generate()), @levelled, slug, kind, level],
                   mode: :savepoint
                 ),
               inspect({kind, slug, level})
      end

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind, level) " <>
                   "VALUES ($1, $2, 'level-1', 'Level 1', 'level', 1)",
                 [Ecto.UUID.dump!(Ash.UUID.generate()), @levelled],
                 mode: :savepoint
               )
    end
  end

  describe "who posts in a level's room" do
    test "a level's own keys post at once; earlier keys only once it sells out; later keys never" do
      sell(@levelled, 1..4)

      # Level 2 has keys 3 to 5, and key 5 is not sold yet.
      assert {:ok, _post} = post(owner(3), "level-2")
      assert {:ok, _post} = post(owner(1), "level-1")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(1), "level-2")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(3), "level-1")

      sell(@levelled, 5)

      assert {:ok, _post} = post(owner(1), "level-2")
      assert {:ok, _post} = post(owner(2), "level-2")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(3), "level-1")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(5), "level-1")

      # Level 3 has only just opened, so level 2 does not reach it yet.
      sell(@levelled, 6)
      assert {:ok, _post} = post(owner(6), "level-3")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(5), "level-3")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(1), "level-3")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(6), "level-2")

      sell(@levelled, 7..10)
      assert {:ok, _post} = post(owner(1), "level-3")
      assert {:ok, _post} = post(owner(5), "level-3")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(10), "level-2")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(10), "level-1")

      # A level that has sold nothing has no room at all.
      assert {:error, %Ash.Error.Invalid{errors: [%RoomUnknownError{}]}} =
               post(owner(1), "level-4")
    end

    test "every key someone holds counts, not only the first" do
      sell(@levelled, 1..7)
      both = %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(1), wallet(7)]}

      # Key 1 alone does not reach level 3 while keys 8 to 10 are unsold;
      # key 7 is a level 3 key.
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(1), "level-3")
      assert {:ok, _post} = post(both, "level-3")
      assert {:ok, _post} = post(both, "level-1")
    end

    test "a key number the fleet never issues posts in no level" do
      sell(@levelled, 1)
      sell(@levelled, 46_366)

      assert {:ok, _post} = post(owner(46_366), "general")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(46_366), "level-1")
      assert {:ok, _post} = post(owner(1), "level-1")

      # Nor does an agent running it.
      runner = agent("c")
      KeyFleet.Agents.ensure_profile!(%{name: "Runner", declared_harness: "local"}, actor: runner)
      request = Keys.request_pairing!(@levelled, 46_366, %{}, actor: runner)
      Keys.approve_pairing!(request, %{}, actor: owner(46_366))

      assert {:ok, _post} = post(runner, "general")
      assert {:error, %Ash.Error.Forbidden{}} = post(runner, "level-1")
    end

    test "an agent posts where the key it runs may" do
      sell(@levelled, 1..4)
      runner = agent("c")
      KeyFleet.Agents.ensure_profile!(%{name: "Runner", declared_harness: "local"}, actor: runner)
      request = Keys.request_pairing!(@levelled, 3, %{}, actor: runner)
      Keys.approve_pairing!(request, %{}, actor: owner(3))

      assert {:ok, _post} = post(runner, "level-2")
      assert {:error, %Ash.Error.Forbidden{}} = post(runner, "level-1")
      assert {:ok, _post} = post(runner, "general")
      assert {:error, %Ash.Error.Forbidden{}} = post(agent("d"), "level-2")
    end

    test "while key ownership is not fresh, nobody posts in any room" do
      sell(@levelled, 1..5)
      ChainHelpers.seed_cursor!(@levelled, observed_at: DateTime.add(DateTime.utc_now(), -3600))

      for slug <- ~w(level-1 level-2 general) do
        assert {:error, %Ash.Error.Forbidden{}} = post(owner(1), slug)
      end

      ChainHelpers.seed_cursor!(@levelled, rescan_from: 5)
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(3), "level-2")
    end

    test "the workspace and the rooms read one rule for which levels a key writes" do
      deploy(@levelled)
      sell(@levelled, 1..7)

      for token_id <- 1..7 do
        {:ok, command} =
          KeyFleet.Graph.Checks.KeyActor.command(owner(token_id), @levelled, token_id, "c", 1_000)

        workspace =
          for "level:" <> level <- command.writable_scopes, do: String.to_integer(level)

        rooms =
          for level <- 1..3, match?({:ok, _}, post(owner(token_id), "level-#{level}")), do: level

        assert rooms == workspace, "key #{token_id}"
      end
    end
  end

  describe "topic rooms" do
    test "a member opens a room for the whole fleet that any member posts in" do
      sell(@levelled, 1..3)

      room =
        Rooms.create_topic_room!(
          %{fleet_id: @levelled, slug: "hull-survey", name: "Hull survey"},
          actor: owner(3)
        )

      assert {room.kind, room.level, room.slug, room.name, room.head_seq} ==
               {:topic, nil, "hull-survey", "Hull survey", 0}

      assert {:ok, _post} = post(owner(1), "hull-survey")
      assert {:ok, _post} = post(owner(3), "hull-survey")
      assert {:error, %Ash.Error.Forbidden{}} = post(human("e"), "hull-survey")
    end

    test "a room that follows a level takes that level's rule, and only its posters open one" do
      sell(@levelled, 1..4)

      assert {:ok, room} =
               Rooms.create_topic_room(
                 %{fleet_id: @levelled, slug: "level-two-plans", name: "Plans", level: 2},
                 actor: owner(3)
               )

      assert {room.kind, room.level} == {:topic, 2}
      assert {:ok, _post} = post(owner(4), "level-two-plans")
      assert {:error, %Ash.Error.Forbidden{}} = post(owner(1), "level-two-plans")

      # Key 1 cannot post in level 2 until it sells out, key 3 never in level 1,
      # and nobody in a level that has sold nothing.
      for {token_id, level} <- [{1, 2}, {3, 1}, {3, 3}, {1, 3}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Rooms.create_topic_room(
                   %{
                     fleet_id: @levelled,
                     slug: "t-#{token_id}-#{level}",
                     name: "T",
                     level: level
                   },
                   actor: owner(token_id)
                 )
      end

      sell(@levelled, 5)
      assert {:ok, _post} = post(owner(1), "level-two-plans")

      assert {:ok, %{level: 2}} =
               Rooms.create_topic_room(
                 %{fleet_id: @levelled, slug: "t-1-2", name: "T", level: 2},
                 actor: owner(1)
               )
    end

    test "only one of the fleet's key holders opens a topic room, and only while ownership is fresh" do
      sell(@levelled, 1)
      input = %{fleet_id: @levelled, slug: "hull-survey", name: "Hull survey"}

      for actor <- [human("e"), agent("d"), nil, @system] do
        assert {:error, %Ash.Error.Forbidden{}} = Rooms.create_topic_room(input, actor: actor)
      end

      ChainHelpers.seed_cursor!(@levelled, observed_at: DateTime.add(DateTime.utc_now(), -3600))
      assert {:error, %Ash.Error.Forbidden{}} = Rooms.create_topic_room(input, actor: owner(1))
      assert Rooms.count_topic_rooms!(@levelled) == 0
    end

    test "a topic room names a real fleet, a level that fleet has, and a free address" do
      sell(@levelled, 1)
      sell("fleet_tech_classic", 1)

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :level}]}} =
               Rooms.create_topic_room(
                 %{fleet_id: "fleet_tech_classic", slug: "levels", name: "Levels", level: 1},
                 actor: owner(1)
               )

      assert {:ok, %{level: nil}} =
               Rooms.create_topic_room(
                 %{fleet_id: "fleet_tech_classic", slug: "levels", name: "Levels"},
                 actor: owner(1)
               )

      for level <- [nil, 1] do
        assert {:error, %Ash.Error.Invalid{errors: [%KeyFleet.Graph.Errors.UnknownFleetError{}]}} =
                 Rooms.create_topic_room(
                   %{fleet_id: "hull_survey", slug: "levels", name: "Levels", level: level},
                   actor: owner(1)
                 )
      end

      for {slug, name, level} <- [
            {"Hull", "Hull", nil},
            {"hull survey", "Hull", nil},
            {"hull--survey", "Hull", nil},
            {"-hull", "Hull", nil},
            {String.duplicate("h", 64), "Hull", nil},
            {"hull", "", nil},
            {"hull", String.duplicate("h", 81), nil},
            {"hull", "Hull", 0},
            {"hull", "Hull", 21},
            # A core room's name, or a level's, in any case and with spaces around.
            {"hull", "General", nil},
            {"hull", " planning ", nil},
            {"hull", "WORK", nil},
            {"hull", "Level 7", nil},
            {"hull", "level 21", nil},
            # Control characters, line breaks and characters that turn text around.
            {"hull", "Hull\nsurvey", nil},
            {"hull", "Hull\tsurvey", nil},
            {"hull", "Hull\u0007survey", nil},
            {"hull", "Hull\u0085survey", nil},
            {"hull", "Hull \u202Eyevrus", nil},
            {"hull", "Hull \u2066survey", nil}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Rooms.create_topic_room(
                   %{fleet_id: @levelled, slug: slug, name: name, level: level},
                   actor: owner(1)
                 ),
               inspect({slug, name, level})
      end

      Rooms.create_topic_room!(%{fleet_id: @levelled, slug: "hull", name: "Hull"},
        actor: owner(1)
      )

      # Names that only start like a kept one are free, and so is any language.
      for {slug, name} <- [{"store", "General store"}, {"levels", "Levels"}, {"kai", "Kāi · 船体"}] do
        assert {:ok, %{name: ^name}} =
                 Rooms.create_topic_room(%{fleet_id: @levelled, slug: slug, name: name},
                   actor: owner(1)
                 )
      end

      assert {:error, %Ash.Error.Invalid{}} =
               Rooms.create_topic_room(%{fleet_id: @levelled, slug: "hull", name: "Other"},
                 actor: owner(1)
               )

      assert Rooms.count_topic_rooms!(@levelled) == 4
    end

    test "a fleet holds 100 topic rooms, whatever its core and level rooms" do
      sell(@levelled, 231)
      member = owner(231)

      for n <- 1..100 do
        Rooms.create_topic_room!(%{fleet_id: @levelled, slug: "topic-#{n}", name: "Topic #{n}"},
          actor: member
        )
      end

      assert length(Rooms.list_rooms!(@levelled)) == 3 + 10 + 100

      assert {:error, %Ash.Error.Invalid{errors: [%TopicRoomLimitError{limit: 100}]}} =
               Rooms.create_topic_room(
                 %{fleet_id: @levelled, slug: "topic-101", name: "Topic 101"},
                 actor: member
               )

      # Another fleet's topics are its own.
      sell("fleet_tech_classic", 1)

      assert {:ok, _room} =
               Rooms.create_topic_room(
                 %{fleet_id: "fleet_tech_classic", slug: "topic-1", name: "Topic 1"},
                 actor: owner(1)
               )

      # Level rooms keep opening once the topics are full.
      sell(@levelled, 232..377)
      assert length(level_rooms(@levelled)) == 11
    end
  end

  defp post(actor, slug) do
    Rooms.send_message(
      %{
        fleet_id: @levelled,
        slug: slug,
        body: "Standing by",
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  defp level_rooms(fleet) do
    for %{kind: :level} = room <- Rooms.list_rooms!(fleet), do: {room.slug, room.name, room.level}
  end

  # The statements that wrote to the rooms table while `fun` ran.
  defp room_writes_during(fun) do
    test_pid = self()
    handler = "level-rooms-test-writes"

    :telemetry.attach(
      handler,
      [:key_fleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "rooms" and not String.starts_with?(meta.query, "SELECT"),
          do: send(test_pid, {:room_write, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_room_writes([])
  end

  defp collect_room_writes(writes) do
    receive do
      {:room_write, query} -> collect_room_writes([query | writes])
    after
      0 -> Enum.reverse(writes)
    end
  end

  # Each room's row version: a rewrite moves it, and a lock marks it.
  defp room_versions(fleet) do
    Repo.query!(
      "SELECT slug, ctid::text, xmin::text, xmax::text FROM keyfleet_app.rooms " <>
        "WHERE fleet_id = $1 ORDER BY slug",
      [fleet]
    ).rows
  end

  defp owner(token_id),
    do: %Actors.Human{human_account_id: token_id, wallet_addresses: [wallet(token_id)]}

  defp human(character),
    do: %Actors.Human{
      human_account_id: 1,
      wallet_addresses: ["0x" <> String.duplicate(character, 40)]
    }

  defp agent(character),
    do: %Actors.Agent{
      wallet_address: "0x" <> String.duplicate(character, 40),
      chain_id: 8453,
      audience: "keyfleet"
    }

  defp wallet(token_id), do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  # A sale as the chain reader handles it: recorded, then the fleet's level
  # rooms opened.
  defp sell(fleet, token_ids) do
    record(fleet, token_ids)
    :ok = Rooms.ensure_level_rooms(fleet)
  end

  defp record(fleet, token_id) when is_integer(token_id), do: record(fleet, [token_id])

  defp record(fleet, token_ids) do
    for token_id <- token_ids do
      Keys.record_epoch!(
        %{
          fleet_id: fleet,
          token_id: token_id,
          ownership_epoch: 0,
          owner_wallet: wallet(token_id),
          block_number: 10,
          block_hash: "0x" <> String.duplicate("a", 64),
          transaction_hash: hash("#{fleet}/#{token_id}"),
          log_index: 0
        },
        actor: @system
      )
    end
  end

  defp transfer(fleet, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: "0x" <> String.duplicate("7", 40),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: hash("#{fleet}/#{token_id}/1"),
        log_index: 0
      },
      actor: @system
    )
  end

  defp deploy(fleet) do
    fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: "0x" <> String.duplicate("1", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1
      },
      actor: @system
    )
  end

  defp hash(text), do: "0x" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end
