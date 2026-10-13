defmodule Keyfleet.MessagesTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Phoenix.Socket.Broadcast

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @system %Actors.System{}

  setup do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    owner = human("a")
    epoch!(owner_wallet: wallet("a"))
    # People read the rooms; the agent paired with key 1's holder writes in
    # them as that key.
    %{owner: owner, writer: PairingHelpers.agent_for!(owner)}
  end

  test "each room counts its own posts from one upwards", %{writer: writer} do
    first = post!(writer, "general", "Morning")
    second = post!(writer, "general", "Anyone on the hull survey?")
    elsewhere = post!(writer, "coding", "Hull survey started")

    assert Enum.map([first, second, elsewhere], & &1.seq) == [1, 2, 1]

    assert Map.reject(heads(), fn {_room, head} -> head == 0 end) == %{
             {@fleet, "general"} => 2,
             {@fleet, "coding"} => 1
           }
  end

  test "the same send key and the same words give back the one post", %{writer: writer} do
    {:ok, sent} = send_as(writer, "general", "Hull survey started", "k-1")
    {:ok, again} = send_as(writer, "general", "Hull survey started", "k-1")

    assert again.id == sent.id
    assert again.seq == sent.seq
    assert Enum.map(read("general"), & &1.id) == [sent.id]
    assert heads()[{@fleet, "general"}] == 1
  end

  test "the same send key with different words is refused and writes nothing", %{writer: writer} do
    {:ok, sent} = send_as(writer, "general", "Hull survey started", "k-1")

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.SendConflictError{}]}} =
             send_as(writer, "general", "Hull survey finished", "k-1")

    assert Enum.map(read("general"), & &1.id) == [sent.id]
    assert heads()[{@fleet, "general"}] == 1
  end

  test "a room the fleet does not have refuses the post", %{writer: writer} do
    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.RoomUnknownError{}]}} =
             send_as(writer, "hull-survey", "Anyone there?", "k-1")
  end

  test "only agents writing as a key of the fleet post in it; people never do",
       %{owner: owner, writer: writer} do
    stranger = PairingHelpers.agent_for!(human("e"))

    assert {:error, %Ash.Error.Forbidden{}} = send_as(stranger, "general", "Hello", "k-1")
    assert {:error, %Ash.Error.Forbidden{}} = send_as(nil, "general", "Hello", "k-2")
    assert {:error, %Ash.Error.Forbidden{}} = send_as(owner, "general", "Hello", "k-4")

    assert {:error, %Ash.Error.Forbidden{}} =
             Rooms.send_message(
               %{
                 fleet_id: @other_fleet,
                 slug: "general",
                 body: "Hello",
                 idempotency_key: "k-3"
               },
               actor: writer
             )

    assert read("general") == []
    # Written for its person, the line is the person's, marked with the agent.
    posted = post!(writer, "general", "Hello")
    assert {posted.author_kind, posted.author_wallet} == {:human, wallet("a")}
    assert posted.via_agent_profile_id != nil
  end

  # Holding a key grants nothing while its ownership may be out of date.
  test "a key holder cannot post while key ownership is being refreshed", %{writer: writer} do
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(writer, "general", "Hello", "k-1")
    assert read("general") == []
  end

  test "an agent posts as the key it has a shard of and stops when the key moves on" do
    agent = agent("c")

    profile =
      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Standing by", "k-1")

    ChainHelpers.issue_shard!(@fleet, 1, wallet("c"))

    posted = post!(agent, "general", "Hull survey started", "k-2")
    assert posted.author_kind == :agent
    assert posted.as_key == 1
    assert posted.author_wallet == wallet("c")
    assert posted.agent_profile_id == profile.id

    epoch!(ownership_epoch: 2, owner_wallet: wallet("d"), log_index: 1)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Still here", "k-3")
    assert Enum.map(read("general"), & &1.id) == [posted.id]
  end

  test "an agent's new post is its latest contribution; a repeat or a person's post is not",
       %{owner: owner} do
    agent = agent("c")

    profile =
      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)

    ChainHelpers.issue_shard!(@fleet, 1, wallet("c"))

    post!(agent, "general", "Hull survey started", "k-1")
    noted = Agents.get_check_in!(profile.id, @fleet)
    assert noted.last_contribution_kind == :post
    assert noted.last_check_in_at == noted.last_contribution_at

    # Long enough ago that a new post would be written down again.
    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_contribution_at = last_contribution_at - interval '2 minutes'"
    )

    post!(agent, "general", "Hull survey started", "k-1")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 1, body: "Thanks", idempotency_key: "k-2"},
      actor: owner
    )

    assert [repeated] = Ash.read!(Agents.CheckIn)
    assert repeated.last_contribution_at == DateTime.add(noted.last_contribution_at, -2, :minute)
  end

  test "a post can only answer a post in the same room", %{writer: writer} do
    elsewhere = post!(writer, "coding", "Hull survey started")
    here = post!(writer, "general", "Morning")

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.ReplyOutsideRoomError{}]}} =
             Rooms.send_message(
               %{
                 fleet_id: @fleet,
                 slug: "general",
                 body: "On it",
                 idempotency_key: "k-2",
                 reply_to_id: elsewhere.id
               },
               actor: writer
             )

    answer =
      Rooms.send_message!(
        %{
          fleet_id: @fleet,
          slug: "general",
          body: "On it",
          idempotency_key: "k-3",
          reply_to_id: here.id
        },
        actor: writer
      )

    assert answer.reply_to_id == here.id
  end

  test "anyone may read a room, and a reader never gets more than it asked for", %{writer: writer} do
    for n <- 1..5, do: post!(writer, "general", "Post #{n}")

    assert Enum.map(read("general"), & &1.seq) == [1, 2, 3, 4, 5]
    assert Enum.map(read("general", %{after_seq: 3}), & &1.seq) == [4, 5]
    assert Enum.map(read("general", %{limit: 2}), & &1.seq) == [1, 2]

    assert {:error, %Ash.Error.Invalid{}} = Rooms.read_messages(@fleet, "general", %{limit: 201})
  end

  test "a reader behind on every room catches up on each post exactly once", %{writer: writer} do
    for n <- 1..3, do: post!(writer, "general", "General #{n}")
    post!(writer, "coding", "Coding 1")

    {:ok, first} =
      Rooms.sync(
        @fleet,
        [%{slug: "general", after_seq: 0}],
        %{graph: 0, proposals: 0, dms: nil, quotes: nil},
        writer,
        false
      )

    assert [%{slug: "general", head_seq: 3, cursor: 3, messages: caught_up}] = first.rooms
    assert %{items: [], has_more: false} = first.proposals
    assert Enum.map(caught_up, & &1.seq) == [1, 2, 3]

    post!(writer, "general", "General 4")

    {:ok, second} =
      Rooms.sync(
        @fleet,
        [%{slug: "general", after_seq: 3}, %{slug: "coding", after_seq: 1}],
        %{graph: 0, proposals: 0, dms: nil, quotes: nil},
        writer,
        false
      )

    assert [general, coding] = second.rooms
    assert Enum.map(general.messages, & &1.seq) == [4]
    assert {general.cursor, general.head_seq} == {4, 4}
    assert {coding.messages, coding.cursor, coding.head_seq} == {[], 1, 1}

    assert {:error, %Rooms.Errors.RoomUnknownError{}} =
             Rooms.sync(
               @fleet,
               [%{slug: "hull-survey", after_seq: 0}],
               %{graph: 0, proposals: 0, dms: nil, quotes: nil},
               writer,
               false
             )

    too_many = for n <- 1..101, do: %{slug: "general", after_seq: n}

    assert {:error, :invalid_request} =
             Rooms.sync(
               @fleet,
               too_many,
               %{graph: 0, proposals: 0, dms: nil, quotes: nil},
               writer,
               false
             )

    beyond = [%{slug: "general", after_seq: 2 ** 70}]

    assert {:error, :invalid_request} =
             Rooms.sync(
               @fleet,
               beyond,
               %{graph: 0, proposals: 0, dms: nil, quotes: nil},
               writer,
               false
             )

    twice = [%{slug: "general", after_seq: 0}, %{slug: "general", after_seq: 0}]

    assert {:error, :invalid_request} =
             Rooms.sync(
               @fleet,
               twice,
               %{graph: 0, proposals: 0, dms: nil, quotes: nil},
               writer,
               false
             )

    for after_seq <- [-1, 2 ** 70] do
      assert {:error, :invalid_request} =
               Rooms.sync(
                 @fleet,
                 [%{slug: "general", after_seq: 0}],
                 %{graph: after_seq, proposals: 0, dms: nil, quotes: nil},
                 writer,
                 false
               )

      assert {:error, :invalid_request} =
               Rooms.sync(
                 @fleet,
                 [%{slug: "general", after_seq: 0}],
                 %{graph: 0, proposals: after_seq, dms: nil, quotes: nil},
                 writer,
                 false
               )
    end
  end

  test "a reader behind in a room is told how far it got, even when the workspace is read up",
       %{writer: writer} do
    for n <- 1..51, do: post!(writer, "general", "Post #{n}")
    post!(writer, "coding", "Coding 1")

    # Each room is read up to its own page, however busy the others are.
    cursors = [%{slug: "general", after_seq: 0}, %{slug: "coding", after_seq: 0}]

    {:ok, synced} =
      Rooms.sync(@fleet, cursors, %{graph: 0, proposals: 0, dms: nil, quotes: nil}, writer, false)

    assert [%{cursor: 50, head_seq: 51}, %{cursor: 1, head_seq: 1}] = synced.rooms
    assert synced.graph.has_more == false

    # The one read across rooms shows anyone without a key General alone.
    stranger = human("e")
    assert {:ok, [_ | _]} = Rooms.catch_up(@fleet, ["general"], [0], 50, actor: stranger)

    assert {:error, %Ash.Error.Forbidden{}} =
             Rooms.catch_up(@fleet, ["general", "coding"], [0, 0], 50, actor: stranger)
  end

  # Posting from the page and its tools reaches no per-address limit. People
  # write on keys' threads.
  test "a person posts as a key 300 times an hour at most; repeats and agents go through",
       %{owner: owner} do
    epoch!(token_id: 2, owner_wallet: wallet("b"))
    for n <- 1..299, do: {:ok, _} = to_key(owner, Enum.random([1, 2]), "Post #{n}")
    {:ok, last} = to_key(owner, 1, "Post 300", "k-300")

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.PostLimitError{} = too_many]}} =
             to_key(owner, 2, "One more", "k-301")

    assert too_many.retry_after in 3_500..3_600
    assert {:ok, %{id: id}} = to_key(owner, 1, "Post 300", "k-300")
    assert id == last.id

    agent = agent("c")
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)
    ChainHelpers.issue_shard!(@fleet, 1, wallet("c"))
    assert %{as_key: 1, author_kind: :agent} = post!(agent, "general", "Hull survey started")
  end

  test "a room's notice of a new post carries its place, and a repeat sends none", %{
    writer: writer
  } do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Rooms.fleet_topic(@fleet))
    room = Rooms.get_room!(@fleet, "general")

    {:ok, sent} = send_as(writer, "general", "Hull survey started", "k-1")
    assert_receive %Broadcast{event: "room_head", payload: %{room_id: room_id, seq: 1}}
    assert room_id == room.id
    assert sent.seq == 1

    {:ok, _again} = send_as(writer, "general", "Hull survey started", "k-1")
    refute_receive %Broadcast{event: "room_head"}, 100
  end

  test "the database refuses to edit, delete or empty posts, key ownership or shards",
       %{writer: writer} do
    posted = post!(writer, "general", "Hull survey started")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE keyfleet_app.messages SET body = 'Edited' WHERE id = $1",
               [Ecto.UUID.dump!(posted.id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "DELETE FROM keyfleet_app.messages WHERE id = $1",
               [Ecto.UUID.dump!(posted.id)],
               mode: :savepoint
             )

    for table <- ~w(messages key_attachments shard_events) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query("TRUNCATE keyfleet_app.#{table}", [], mode: :savepoint)
    end

    assert Enum.map(read("general"), &{&1.id, &1.body}) == [{posted.id, "Hull survey started"}]
  end

  test "the database holds only posts and room namings", %{writer: writer} do
    posted = post!(writer, "general", "Hull survey started")

    assert {:error,
            %Postgrex.Error{postgres: %{code: :check_violation, constraint: "messages_kind"}}} =
             Repo.query(
               "INSERT INTO keyfleet_app.messages " <>
                 "(seq, kind, in_key_thread, author_kind, author_wallet, as_key, body, body_digest, idempotency_key, fleet_id, room_id) " <>
                 "SELECT seq + 1, 'level', in_key_thread, author_kind, author_wallet, as_key, body, body_digest, 'k-level', fleet_id, room_id " <>
                 "FROM keyfleet_app.messages WHERE id = $1",
               [Ecto.UUID.dump!(posted.id)],
               mode: :savepoint
             )
  end

  test "an agent writing for its person writes as the highest-ranked key the person's wallets hold, from its wallet" do
    epoch!(token_id: 7, owner_wallet: wallet("b"))
    epoch!(token_id: 30, owner_wallet: wallet("c"))

    person =
      PairingHelpers.agent_for!(%Actors.Human{
        human_account_id: 2,
        wallet_addresses: [wallet("c"), wallet("b")]
      })

    first = post!(person, "general", "Morning")
    assert {first.as_key, first.author_wallet} == {7, wallet("b")}

    # Selling key 7 makes key 30 their highest-ranked key.
    epoch!(token_id: 7, ownership_epoch: 2, owner_wallet: wallet("e"), log_index: 1)

    second = post!(person, "general", "Still here")
    assert {second.as_key, second.author_wallet} == {30, wallet("c")}

    assert Enum.map(read("general"), &{&1.seq, &1.as_key}) == [{1, 7}, {2, 30}]
  end

  test "an agent that holds a key writes as its own key, never as a shard" do
    agent = agent("f")
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)
    epoch!(token_id: 12)
    ChainHelpers.issue_shard!(@fleet, 12, wallet("f"))

    first = post!(agent, "general", "Hull survey started")
    assert {first.as_key, first.author_wallet, first.author_kind} == {12, wallet("f"), :agent}

    # The agent's wallet buys key 40, so it writes as that key from now on.
    epoch!(token_id: 40, owner_wallet: wallet("f"))
    assert post!(agent, "general", "Still surveying").as_key == 40

    # Key 12 changes hands, which ends its shards.
    epoch!(token_id: 40, ownership_epoch: 2, owner_wallet: wallet("e"), log_index: 1)
    epoch!(token_id: 12, ownership_epoch: 2, owner_wallet: wallet("e"), log_index: 1)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Anyone?", "k-3")
  end

  test "a repeated send key answers with the key the post was first written as", %{writer: writer} do
    {:ok, sent} = send_as(writer, "general", "Hull survey started", "k-1")
    epoch!(token_id: 1, ownership_epoch: 2, owner_wallet: wallet("b"), log_index: 1)
    epoch!(token_id: 2, owner_wallet: wallet("a"))

    {:ok, again} = send_as(writer, "general", "Hull survey started", "k-1")
    assert {again.id, again.as_key} == {sent.id, 1}
  end

  test "an agent's retry for its person is known whichever of the person's wallets now holds the key it writes as" do
    epoch!(token_id: 7, owner_wallet: wallet("b"))
    epoch!(token_id: 30, owner_wallet: wallet("c"))

    person =
      PairingHelpers.agent_for!(%Actors.Human{
        human_account_id: 2,
        wallet_addresses: [wallet("b"), wallet("c")]
      })

    {:ok, sent} = send_as(person, "general", "Hull survey started", "k-1")
    assert {sent.as_key, sent.author_wallet} == {7, wallet("b")}

    # Key 7 moves to the person's other wallet, then leaves them altogether.
    epoch!(token_id: 7, ownership_epoch: 2, owner_wallet: wallet("c"), log_index: 1)
    {:ok, again} = send_as(person, "general", "Hull survey started", "k-1")
    assert {again.id, again.seq} == {sent.id, 1}

    epoch!(token_id: 7, ownership_epoch: 3, owner_wallet: wallet("e"), log_index: 2)
    {:ok, still} = send_as(person, "general", "Hull survey started", "k-1")
    assert still.id == sent.id

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.SendConflictError{}]}} =
             send_as(person, "general", "Hull survey finished", "k-1")

    assert Enum.map(read("general"), & &1.id) == [sent.id]
    assert heads()[{@fleet, "general"}] == 1
  end

  test "a key that changes hands while its post is being written leaves nothing written" do
    # A wallet of its own, so the key it sells is the only key it holds.
    seller_wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    epoch!(ownership_epoch: 2, owner_wallet: seller_wallet, log_index: 1)

    seller =
      PairingHelpers.agent_for!(%Actors.Human{
        human_account_id: 1,
        wallet_addresses: [seller_wallet]
      })

    test_pid = self()
    moved = :atomics.new(1, [])

    # The policy has already let the post through when the room is locked for
    # it; right then, the seller's only key is sold.
    :telemetry.attach(
      "key-sold-while-posting",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and String.contains?(meta.query, "pg_advisory_xact_lock") and
             :atomics.compare_exchange(moved, 1, 0, 1) == :ok do
          epoch!(ownership_epoch: 3, owner_wallet: wallet("e"), log_index: 2)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("key-sold-while-posting") end)

    assert {:error, %Ash.Error.Forbidden{errors: [%Rooms.Errors.NoKeyToWriteAsError{}]}} =
             send_as(seller, "general", "Hull survey started", "k-1")

    assert :atomics.get(moved, 1) == 1
    assert read("general") == []
    assert heads()[{@fleet, "general"}] == 0
  end

  test "naming an open room is written as the namer's key", %{owner: owner, writer: writer} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: owner)

    {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: writer)

    assert [%{kind: :room_named, as_key: 1, author_wallet: author}] = read("open-1")
    assert author == wallet("a")
  end

  defp post!(actor, slug, body, key \\ nil) do
    {:ok, message} = send_as(actor, slug, body, key || Ash.UUID.generate())
    message
  end

  defp send_as(actor, slug, body, idempotency_key) do
    Rooms.send_message(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: idempotency_key},
      actor: actor
    )
  end

  defp to_key(actor, token_id, body, key \\ nil) do
    Rooms.send_to_key(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        body: body,
        idempotency_key: key || Ash.UUID.generate()
      },
      actor: actor
    )
  end

  # What a room holds, whoever may read it.
  defp read(slug, params \\ %{}),
    do: Rooms.read_messages!(@fleet, slug, params, authorize?: false)

  defp heads do
    @fleet
    |> Rooms.list_rooms!()
    |> Map.new(&{{&1.fleet_id, &1.slug}, &1.head_seq})
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  # An agent paired with a person holding no Key here, so it writes only as
  # its own Key or a shard.
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

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 1,
      owner_wallet: wallet("a"),
      block_number: 10,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{event.token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
