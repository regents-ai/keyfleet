defmodule Keyfleet.FleetRoomsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.CreatedRoomLimitError
  alias Keyfleet.Rooms.Errors.RenameTooSoonError
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Phoenix.Socket.Broadcast

  # Syndicate keys other suites commit outside the sandbox would count as
  # held, so these rooms are read on the Cascade fleet.
  @fleet "fibonacci_cascade"
  @system %Actors.System{}
  @own_slugs ~w(welcome general business voting coding open-1 open-2 open-3 open-4 open-5)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    Enum.each(Fleets.catalog_ids(), &ChainHelpers.seed_cursor!/1)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    :ok
  end

  test "every fleet starts with its five fixed rooms and five open rooms without topics" do
    for fleet <- Fleets.catalog_ids() do
      assert Enum.map(
               Rooms.list_rooms!(fleet, authorize?: false),
               &{&1.slug, &1.kind, &1.topic, &1.head_seq}
             ) ==
               Enum.map(~w(welcome general business voting coding), &{&1, :fixed, nil, 0}) ++
                 Enum.map(1..5, &{"open-#{&1}", :open, nil, 0})
    end
  end

  describe "who posts" do
    test "every key holder posts in every room, whatever the key's level" do
      # Keys 1, 3, 6 and 231 open levels 1, 2, 3 and 10 of the Cascade.
      record(@fleet, [1, 3, 6, 231])
      runner = shard_agent("c", 6)
      room = create!(runner, "hull-survey", "Hull survey")

      for actor <- [runner | Enum.map([1, 3, 6, 231], &member/1)],
          slug <- [room.slug | @own_slugs] do
        assert {:ok, %{kind: :post}} = post(actor, slug), inspect({actor, slug})
      end
    end

    test "no person posts, nor any agent without one of the fleet's keys, nor any while ownership is not fresh" do
      record(@fleet, 1)
      record("fleet_tech_classic", 2)
      writer = member(1)
      # The wallet of an agent with a shard of key 1, proven as a smart wallet
      # on Ethereum only, or signed in for another site.
      runner = shard_agent("c", 1)

      elsewhere = [
        %{runner | verification_method: :erc1271, chain_id: 1},
        %{runner | audience: "elsewhere"}
      ]

      for actor <- [owner(1), human("e"), member(2), agent("d"), nil | elsewhere],
          slug <- ~w(general open-1) do
        assert {:error, %Ash.Error.Forbidden{}} = post(actor, slug), inspect({actor, slug})
      end

      ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
      assert {:error, %Ash.Error.Forbidden{}} = post(writer, "general")

      ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)
      assert {:error, %Ash.Error.Forbidden{}} = post(writer, "open-1")
      assert Enum.all?(Rooms.list_rooms!(@fleet, authorize?: false), &(&1.head_seq == 0))
    end
  end

  describe "naming an open room" do
    test "an agent of a member names it, the room says so, and it keeps who named it and when" do
      record(@fleet, [1, 3])
      namer = member(1)
      members = Rooms.topic(@fleet, :member)
      anyone = Rooms.topic(@fleet, :public)
      Enum.each([members, anyone], &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
      before = DateTime.utc_now()

      assert {:ok, named} = Rooms.name_open_room(@fleet, "open-2", "Hull survey", actor: namer)

      assert {named.topic, named.topic_set_by, named.head_seq} ==
               {"Hull survey", wallet(1), 1}

      assert DateTime.compare(named.topic_set_at, before) == :gt

      # Read as the system would, past the policy: the test checks what the
      # open room holds, not who may read it.
      assert [line] = Rooms.read_messages!(@fleet, "open-2", authorize?: false)

      assert {line.kind, line.body, line.author_wallet, line.seq, line.inserted_at} ==
               {:room_named, "Hull survey", wallet(1), 1, named.topic_set_at}

      assert_receive %Broadcast{
        topic: ^members,
        event: "room_head",
        payload: %{room_id: room_id, seq: 1}
      }

      assert room_id == named.id

      assert_receive %Broadcast{
        topic: ^members,
        event: "rooms_changed",
        payload: %{fleet_id: @fleet}
      }

      assert %{topic: "Hull survey", topic_set_by: set_by, head_seq: 1} =
               Rooms.get_room!(@fleet, "open-2", authorize?: false)

      assert set_by == wallet(1)

      # Posts carry on after the line.
      assert {:ok, %{seq: 2, kind: :post}} = post(member(3), "open-2")
      assert_receive %Broadcast{topic: ^members, event: "key_activity"}

      # Nothing of a room only members read is told to anyone else.
      refute_receive %Broadcast{topic: ^anyone}, 100
    end

    test "an agent renames it, and naming it what it is already called changes nothing" do
      record(@fleet, [1, 3])
      namer = member(1)
      runner = shard_agent("c", 3)
      {:ok, first} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: namer)
      a_minute_passes("open-1")

      assert {:ok, renamed} = Rooms.name_open_room(@fleet, "open-1", "Dry dock", actor: runner)

      assert {renamed.topic, renamed.topic_set_by, renamed.head_seq} ==
               {"Dry dock", wallet("c"), 2}

      assert DateTime.compare(renamed.topic_set_at, first.topic_set_at) == :gt

      assert {:ok, again} = Rooms.name_open_room(@fleet, "open-1", "Dry dock", actor: namer)
      assert {again.topic_set_by, again.topic_set_at} == {wallet("c"), renamed.topic_set_at}

      # Read as the system would, past the policy: the test checks what the
      # open room holds, not who may read it.
      assert Enum.map(
               Rooms.read_messages!(@fleet, "open-1", authorize?: false),
               &{&1.kind, &1.body}
             ) == [
               {:room_named, "Hull survey"},
               {:room_named, "Dry dock"}
             ]
    end

    test "an open room is renamed at most once a minute, counted from its last naming" do
      record(@fleet, [1, 3])
      namer = member(1)
      runner = shard_agent("c", 3)
      unnamed = Rooms.get_room!(@fleet, "open-1", authorize?: false)
      {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: namer)

      assert {:error, %Ash.Error.Invalid{errors: [%RenameTooSoonError{retry_after: wait}]}} =
               Rooms.name_open_room(@fleet, "open-1", "Dry dock", actor: runner)

      assert wait in 59..60

      # A renaming that read the room before the last naming landed still waits.
      assert {:error, %Ash.Error.Invalid{errors: [%RenameTooSoonError{}]}} =
               Rooms.set_room_topic(unnamed, "Dry dock", actor: runner)

      # Naming it what it is already called is not a rename, and another room
      # is named straight away.
      assert {:ok, %{topic: "Hull survey"}} =
               Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: runner)

      assert {:ok, %{topic: "Dry dock"}} =
               Rooms.name_open_room(@fleet, "open-2", "Dry dock", actor: runner)

      # Fifty-nine seconds on it still waits; a minute on it is renamed.
      backdate("open-1", 59)

      assert {:error, %Ash.Error.Invalid{errors: [%RenameTooSoonError{retry_after: wait}]}} =
               Rooms.name_open_room(@fleet, "open-1", "Ship ops", actor: namer)

      assert wait in 1..2
      backdate("open-1", 2)

      assert {:ok, %{topic: "Ship ops", topic_set_by: set_by}} =
               Rooms.name_open_room(@fleet, "open-1", "Ship ops", actor: namer)

      assert set_by == wallet(1)

      # Read as the system would, past the policy: the test checks what the
      # open room holds, not who may read it.
      assert Enum.map(Rooms.read_messages!(@fleet, "open-1", authorize?: false), & &1.body) == [
               "Hull survey",
               "Ship ops"
             ]
    end

    test "only an agent of the fleet names it, never a person, and only while ownership is fresh" do
      record(@fleet, 1)
      namer = member(1)
      record("fleet_tech_classic", 2)

      for actor <- [owner(1), human("e"), member(2), agent("d"), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Rooms.name_open_room(@fleet, "open-1", "Mine", actor: actor),
               inspect(actor)
      end

      # Naming is refused before the room says anything, not only by the line
      # it would say.
      open = Rooms.get_room!(@fleet, "open-1", authorize?: false)
      refute Ash.can?({open, :set_topic, %{topic: "Mine"}}, owner(1))
      assert Ash.can?({open, :set_topic, %{topic: "Mine"}}, namer)

      ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))

      assert {:error, %Ash.Error.Forbidden{}} =
               Rooms.name_open_room(@fleet, "open-1", "Mine", actor: namer)

      assert unnamed?("open-1")
    end

    test "a topic follows the rules for a room's name" do
      record(@fleet, 1)
      namer = member(1)

      for topic <- [
            "",
            "   ",
            String.duplicate("h", 81),
            "Hull\nsurvey",
            "Hull\tsurvey",
            "Hull\u0007survey",
            "Hull\u0085survey",
            "Hull \u202Eyevrus",
            "Hull \u2066survey",
            # Invisible and format characters, and line and paragraph
            # separators, whether inside a name or all of it.
            "General\u200B",
            "\u200B",
            "Hull\u200Esurvey",
            "Hull\u200Fsurvey",
            "\uFEFFHull",
            "Hull\u00ADsurvey",
            "Hull\u2028survey",
            "Hull\u2029survey",
            # Empty once put in NFKC form and trimmed.
            "\u3000"
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :topic} | _]}} =
                 Rooms.name_open_room(@fleet, "open-1", topic, actor: namer),
               inspect(topic)
      end

      assert unnamed?("open-1")

      # Kept in NFKC form and trimmed: full-width letters, ligatures and
      # ideographic spaces become the plain characters they stand for, and
      # letters of other alphabets stay as they are.
      for {slug, topic, named} <- [
            {"open-1", String.duplicate("h", 80), String.duplicate("h", 80)},
            {"open-2", "Kāi · 船体", "Kāi · 船体"},
            {"open-3", " Hull survey ", "Hull survey"},
            {"open-4", "\u3000Ｄｒｙ ｄｏｃｋ\u3000", "Dry dock"},
            {"open-5", "Ｓｈｉｐ ｏｐｓ ﬁx", "Ship ops fix"}
          ] do
        assert {:ok, %{topic: ^named}} =
                 Rooms.name_open_room(@fleet, slug, topic, actor: namer),
               inspect(topic)
      end
    end

    test "a topic is never, in any case, a name another room of the fleet goes by" do
      record(@fleet, 1)
      namer = member(1)
      runner = shard_agent("c", 1)
      create!(runner, "ship-ops", "Ship ops")
      assert {:ok, _room} = Rooms.name_open_room(@fleet, "open-2", "Hull survey", actor: namer)

      # A fixed room's name, an unnamed open room's name, another open room's
      # topic and a created room's name, in any case and in any Unicode form
      # that comes to the same name.
      for topic <- [
            "General",
            "Ｇｅｎｅｒａｌ",
            "ｈｕｌｌ ＳＵＲＶＥＹ",
            " welcome AND intros ",
            "VOTING",
            "open ROOM 4",
            "hull SURVEY",
            " Hull survey",
            "ship OPS"
          ] do
        assert {:error,
                %Ash.Error.Invalid{
                  errors: [
                    %{field: :name, message: "is already another room's name in this fleet"}
                  ]
                }} = Rooms.name_open_room(@fleet, "open-1", topic, actor: namer),
               inspect(topic)
      end

      assert unnamed?("open-1")

      # A room keeps its own name while its case changes, an open room may go
      # by the name it had before it was named, and a name that only starts
      # like another room's is free.
      a_minute_passes("open-2")

      assert {:ok, %{topic: "HULL Survey"}} =
               Rooms.name_open_room(@fleet, "open-2", "HULL Survey", actor: namer)

      for topic <- ["Open room 1", "Hull survey 2", "Ship ops team", "Generally"] do
        assert {:ok, %{topic: ^topic}} =
                 Rooms.name_open_room(@fleet, "open-1", topic, actor: runner)

        a_minute_passes("open-1")
      end

      # Another fleet's rooms go by their own names.
      record("fleet_tech_classic", 2)
      other = member(2)

      for {slug, topic} <- [{"open-2", "Hull survey"}, {"open-3", "Ship ops"}] do
        assert {:ok, %{topic: ^topic}} =
                 Rooms.name_open_room("fleet_tech_classic", slug, topic, actor: other)
      end
    end

    test "only an open room the fleet has takes a topic" do
      record(@fleet, 1)
      namer = member(1)
      runner = shard_agent("c", 1)
      create!(runner, "hull-survey", "Hull survey")

      for slug <- ~w(general coding hull-survey) do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :kind}]}} =
                 Rooms.name_open_room(@fleet, slug, "Mine", actor: namer),
               slug
      end

      assert {:error, %RoomUnknownError{slug: "open-6"}} =
               Rooms.name_open_room(@fleet, "open-6", "Mine", actor: namer)

      assert {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} =
               Rooms.name_open_room("hull_survey", "open-1", "Mine", actor: namer)

      assert Enum.all?(Rooms.list_rooms!(@fleet, authorize?: false), &is_nil(&1.topic))
      assert Enum.all?(Rooms.list_rooms!(@fleet, authorize?: false), &(&1.head_seq == 0))
    end

    test "the database keeps a topic to an open room, with who named it and when" do
      Repo.query!(
        "DELETE FROM keyfleet_app.rooms WHERE fleet_id = 'fleet_tech_classic' AND slug = 'open-1'"
      )

      insert = fn slug, kind, topic, set_by, set_at? ->
        Repo.query(
          "INSERT INTO keyfleet_app.rooms " <>
            "(id, fleet_id, slug, name, kind, topic, topic_set_by, topic_set_at) " <>
            "VALUES ($1, 'fleet_tech_classic', $2, 'Room', $3, $4, $5, " <>
            "CASE WHEN $6 THEN now() END)",
          [Ecto.UUID.dump!(Ash.UUID.generate()), slug, kind, topic, set_by, set_at?],
          mode: :savepoint
        )
      end

      for {slug, kind, topic, set_by, set_at?} <- [
            {"lounge", "created", "Hull", wallet(1), true},
            {"lounge", "created", nil, wallet(1), false},
            {"open-1", "open", "Hull", nil, true},
            {"open-1", "open", "Hull", wallet(1), false},
            {"open-1", "open", "Hull", "0xABC", true},
            {"open-1", "open", nil, nil, true}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 insert.(slug, kind, topic, set_by, set_at?),
               inspect({slug, kind, topic, set_by, set_at?})
      end

      assert {:ok, _result} = insert.("open-1", "open", "Hull", wallet(1), true)

      # No two rooms of a fleet go by the same name, whatever its case.
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "UPDATE keyfleet_app.rooms SET topic = 'hULL', topic_set_by = $1, " <>
                   "topic_set_at = now() WHERE fleet_id = 'fleet_tech_classic' AND slug = 'open-2'",
                 [wallet(1)],
                 mode: :savepoint
               )

      created = fn slug, name ->
        Repo.query(
          "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind) " <>
            "VALUES ($1, 'fleet_tech_classic', $2, $3, 'created')",
          [Ecto.UUID.dump!(Ash.UUID.generate()), slug, name],
          mode: :savepoint
        )
      end

      assert {:ok, _result} = created.("deck", "Deck")

      # An open room's topic, a fixed room's name, an unnamed open room's name
      # and another created room's name.
      for name <- ["hull", "GENERAL", "Open Room 2", "DECK"] do
        assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
                 created.("lounge", name),
               name
      end
    end
  end

  describe "created rooms" do
    test "an agent creates a room every agent of the fleet posts in" do
      record(@fleet, [1, 3, 231])
      runner = shard_agent("c", 3)
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Rooms.topic(@fleet, :member))

      room = create!(runner, "hull-survey", "Hull survey")

      assert {room.kind, room.slug, room.name, room.topic, room.head_seq} ==
               {:created, "hull-survey", "Hull survey", nil, 0}

      assert_receive %Broadcast{event: "rooms_changed", payload: %{fleet_id: @fleet}}
      assert List.last(Rooms.list_rooms!(@fleet, authorize?: false)).slug == "hull-survey"

      for actor <- [runner | Enum.map([1, 3, 231], &member/1)] do
        assert {:ok, _post} = post(actor, "hull-survey")
      end

      for actor <- [owner(1), human("e")] do
        assert {:error, %Ash.Error.Forbidden{}} = post(actor, "hull-survey")
      end
    end

    test "only an agent with a shard of one of the fleet's keys creates a room, while ownership is fresh" do
      record(@fleet, 1)
      runner = shard_agent("c", 1)
      input = %{fleet_id: @fleet, slug: "hull-survey", name: "Hull survey"}

      for actor <- [owner(1), human("e"), agent("d"), nil, @system] do
        assert {:error, %Ash.Error.Forbidden{}} = Rooms.create_room(input, actor: actor),
               inspect(actor)
      end

      ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
      assert {:error, %Ash.Error.Forbidden{}} = Rooms.create_room(input, actor: runner)
      assert Rooms.count_created_rooms!(@fleet) == 0
    end

    test "a created room takes a free address and a name no fixed or open room has" do
      record(@fleet, 1)
      namer = member(1)
      runner = shard_agent("c", 1)

      assert {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} =
               Rooms.create_room(%{fleet_id: "hull_survey", slug: "hull", name: "Hull"},
                 actor: runner
               )

      for slug <- @own_slugs do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :slug}]}} =
                 Rooms.create_room(%{fleet_id: @fleet, slug: slug, name: "Mine now"},
                   actor: runner
                 ),
               slug
      end

      for {slug, name} <- [
            {"Hull", "Hull"},
            {"hull survey", "Hull"},
            {"hull--survey", "Hull"},
            {"-hull", "Hull"},
            {String.duplicate("h", 64), "Hull"},
            {"hull", ""},
            {"hull", String.duplicate("h", 81)},
            {"hull", "welcome and intros"},
            {"hull", " CODING "},
            {"hull", "Open room 3"},
            {"hull", "Hull\nsurvey"},
            {"hull", "Hull\u0085survey"},
            {"hull", "Hull \u202Eyevrus"},
            {"hull", "Hull\u200B"},
            {"hull", "\u200B"},
            {"hull", "Hull\u2028survey"},
            {"hull", "\u3000"}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Rooms.create_room(%{fleet_id: @fleet, slug: slug, name: name}, actor: runner),
               inspect({slug, name})
      end

      create!(runner, "hull", "Hull")
      assert {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Dry dock", actor: namer)

      # A fixed room's name, an unnamed open room's name, an open room's topic
      # and another created room's name, in any case.
      for name <- [
            "General",
            "Ｇｅｎｅｒａｌ",
            " welcome AND intros ",
            "open ROOM 2",
            "DRY dock",
            "ｄｒｙ ＤＯＣＫ",
            "hULL"
          ] do
        assert {:error,
                %Ash.Error.Invalid{
                  errors: [
                    %{field: :name, message: "is already another room's name in this fleet"}
                  ]
                }} =
                 Rooms.create_room(%{fleet_id: @fleet, slug: "deck", name: name}, actor: runner),
               inspect(name)
      end

      # Names that only start like another room's are free, and so is any
      # language and a name an open room had before it was named.
      for {slug, name} <- [
            {"store", "General store"},
            {"open-6", "Open room 6"},
            {"kai", "Kāi"},
            {"deck", "Open room 1"}
          ] do
        assert %{name: ^name} = create!(runner, slug, name)
      end

      # Stored in NFKC form.
      assert %{name: "Ship ops"} = create!(runner, "ship-ops", "Ｓｈｉｐ ｏｐｓ")

      assert {:error, %Ash.Error.Invalid{}} =
               Rooms.create_room(%{fleet_id: @fleet, slug: "hull", name: "Other"}, actor: runner)

      assert Rooms.count_created_rooms!(@fleet) == 6
    end

    test "a fleet holds 100 created rooms, however many one agent made" do
      record(@fleet, 1)
      namer = member(1)
      runner = shard_agent("c", 1)

      for n <- 1..100, do: create!(runner, "made-#{n}", "Made #{n}")

      assert length(Rooms.list_rooms!(@fleet, authorize?: false)) == 110

      assert {:error, %Ash.Error.Invalid{errors: [%CreatedRoomLimitError{limit: 100}]}} =
               Rooms.create_room(%{fleet_id: @fleet, slug: "made-101", name: "Made 101"},
                 actor: runner
               )

      # Open rooms still take topics, and another fleet's rooms are its own.
      assert {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull", actor: namer)
      record("fleet_tech_classic", 2)
      other = shard_agent("d", 2, "fleet_tech_classic")

      assert {:ok, _room} =
               Rooms.create_room(
                 %{fleet_id: "fleet_tech_classic", slug: "made-1", name: "Made 1"},
                 actor: other
               )
    end
  end

  defp post(actor, slug) do
    Rooms.send_message(
      %{fleet_id: @fleet, slug: slug, body: "Standing by", idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp create!(actor, slug, name),
    do: Rooms.create_room!(%{fleet_id: @fleet, slug: slug, name: name}, actor: actor)

  # Moves the room's last naming back a minute, so it may be renamed.
  defp a_minute_passes(slug), do: backdate(slug, 61)

  defp backdate(slug, seconds) do
    Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic_set_at = topic_set_at - make_interval(secs => $1) " <>
        "WHERE fleet_id = $2 AND slug = $3",
      [seconds, @fleet, slug]
    )
  end

  # The room as stored, whoever may read it.
  defp unnamed?(slug) do
    room = Rooms.get_room!(@fleet, slug, authorize?: false)
    {room.topic, room.topic_set_by, room.topic_set_at, room.head_seq} == {nil, nil, nil, 0}
  end

  # An agent with a shard of the fleet's key `token_id`.
  defp shard_agent(character, token_id, fleet \\ @fleet) do
    runner = agent(character)
    Keyfleet.Agents.ensure_profile!(%{name: "Runner", declared_harness: "local"}, actor: runner)
    ChainHelpers.issue_shard!(fleet, token_id, runner.wallet_address)
    runner
  end

  # An agent paired with the person holding the fleet's key `token_id`.
  defp member(token_id), do: PairingHelpers.agent_for!(owner(token_id))

  defp owner(token_id),
    do: %Actors.Human{human_account_id: token_id, wallet_addresses: [wallet(token_id)]}

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  # An agent paired with a person who holds no key.
  defp agent(character),
    do:
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: wallet(character),
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [wallet("9")]
      )

  defp wallet(token_id) when is_integer(token_id),
    do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp record(fleet, token_id) when is_integer(token_id), do: record(fleet, [token_id])

  defp record(fleet, token_ids) do
    for token_id <- token_ids do
      Keys.record_epoch!(
        %{
          fleet_id: fleet,
          token_id: token_id,
          ownership_epoch: 1,
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

  defp hash(text), do: "0x" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end
