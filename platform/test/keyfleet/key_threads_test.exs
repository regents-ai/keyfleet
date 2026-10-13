defmodule Keyfleet.KeyThreadsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.KeyUnknownError
  alias Keyfleet.Rooms.Errors.ReplyOutsideRoomError
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Phoenix.Socket.Broadcast

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  # Keys 1, 5 and 7 are sold, to three different people. A test database shared
  # with other suites may hold keys of theirs too.
  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    for {token_id, owner} <- [{1, "a"}, {5, "b"}, {7, "c"}], do: epoch!(token_id, wallet(owner))
    # People write on keys' threads; in the rooms their agents write for them.
    %{
      first: human("a"),
      fifth: human("b"),
      first_agent: PairingHelpers.agent_for!(human("a")),
      fifth_agent: PairingHelpers.agent_for!(human("b"))
    }
  end

  test "a key's first post opens its thread, and later posts join it",
       %{first: first, fifth: fifth} do
    assert Rooms.get_key_thread!(@fleet, 5) == nil

    opening = to_key!(first, 5, "Welcome aboard")
    thread = Rooms.get_key_thread!(@fleet, 5)

    assert {thread.slug, thread.name, thread.kind, thread.token_id} ==
             {"key-5", "Key 5", :key, 5}

    answer = to_key!(fifth, 5, "Glad to be here", reply_to_id: opening.id)

    assert {opening.room_id, opening.seq, opening.as_key} == {thread.id, 1, 1}
    assert {answer.room_id, answer.seq, answer.as_key} == {thread.id, 2, 5}
    assert Rooms.get_key_thread!(@fleet, 5).head_seq == 2

    assert Enum.map(Rooms.read_key_thread!(@fleet, 5), &{&1.seq, &1.body}) ==
             [{1, "Welcome aboard"}, {2, "Glad to be here"}]

    assert Enum.map(Rooms.read_key_thread!(@fleet, 5, %{after_seq: 1}), & &1.seq) == [2]
  end

  test "a repeated send key gives back the one post in the thread", %{first: first} do
    {:ok, sent} = send_to_key(first, 5, "Welcome aboard", "k-1")
    {:ok, again} = send_to_key(first, 5, "Welcome aboard", "k-1")

    assert {again.id, again.as_key} == {sent.id, 1}
    assert Rooms.get_key_thread!(@fleet, 5).head_seq == 1
  end

  test "key threads stay out of the fleet's rooms", %{first: first, first_agent: first_agent} do
    to_key!(first, 5, "Welcome aboard")

    refute Enum.any?(Rooms.list_rooms!(@fleet, authorize?: false), &(&1.kind == :key))
    assert Rooms.get_room!(@fleet, "key-5", authorize?: false) == nil
    assert Rooms.read_messages!(@fleet, "key-5", actor: first) == []

    assert {:error, %RoomUnknownError{slug: "key-5"}} =
             Rooms.sync(
               @fleet,
               [%{slug: "key-5", after_seq: 0}],
               %{graph: 0, proposals: 0, dms: nil, quotes: nil},
               first,
               false
             )

    assert {:error, %Ash.Error.Invalid{errors: [%RoomUnknownError{}]}} =
             Rooms.send_message(
               %{fleet_id: @fleet, slug: "key-5", body: "Hello", idempotency_key: "k-2"},
               actor: first_agent
             )
  end

  test "no room can take a key's address, but a room may be called after a key",
       %{first: first} do
    to_key!(first, 5, "Welcome aboard")
    runner = shard_agent("f", 7)

    for slug <- ["key-5", "key-9", "key-12345"] do
      assert {:error, %Ash.Error.Invalid{}} =
               Rooms.create_room(%{fleet_id: @fleet, slug: slug, name: "Mine"}, actor: runner),
             slug
    end

    assert {:ok, room} =
             Rooms.create_room(%{fleet_id: @fleet, slug: "hull", name: "Key 5"}, actor: runner)

    assert {room.slug, room.name} == {"hull", "Key 5"}

    assert {:ok, keyed} =
             Rooms.create_room(%{fleet_id: @fleet, slug: "key-five", name: "Key five"},
               actor: runner
             )

    assert keyed.slug == "key-five"
  end

  test "a key the fleet has not sold has no thread", %{first: first} do
    unsold = unsold_key()

    assert {:error, %Ash.Error.Invalid{errors: [%KeyUnknownError{token_id: ^unsold}]}} =
             send_to_key(first, unsold, "Anyone there?", "k-1")

    assert {:error, %Ash.Error.Invalid{errors: [%KeyUnknownError{token_id: ^unsold}]}} =
             Rooms.read_key_thread(@fleet, unsold)

    assert Rooms.get_key_thread!(@fleet, unsold) == nil
  end

  test "a sold key nobody has written to reads empty and opens no thread" do
    assert Rooms.read_key_thread!(@fleet, 7) == []
    assert Rooms.get_key_thread!(@fleet, 7) == nil
  end

  test "a reply answers a post in its own thread or room only",
       %{first: first, first_agent: first_agent} do
    in_room = post!(first_agent, "general", "Morning")
    in_thread = to_key!(first, 5, "Welcome aboard")

    assert {:error, %Ash.Error.Invalid{errors: [%ReplyOutsideRoomError{}]}} =
             send_to_key(first, 5, "Replying", "k-1", reply_to_id: in_room.id)

    assert {:error, %Ash.Error.Invalid{errors: [%ReplyOutsideRoomError{}]}} =
             send_to_key(first, 7, "Replying", "k-2", reply_to_id: in_thread.id)

    assert {:error, %Ash.Error.Invalid{errors: [%ReplyOutsideRoomError{}]}} =
             Rooms.send_message(
               %{
                 fleet_id: @fleet,
                 slug: "general",
                 body: "Replying",
                 idempotency_key: "k-3",
                 reply_to_id: in_thread.id
               },
               actor: first_agent
             )

    assert Rooms.get_key_thread!(@fleet, 7) == nil
  end

  test "only the fleet's members write to a thread, and only while ownership is fresh",
       %{first: first} do
    assert {:error, %Ash.Error.Forbidden{}} = send_to_key(human("e"), 5, "Hello", "k-1")
    assert {:error, %Ash.Error.Forbidden{}} = send_to_key(nil, 5, "Hello", "k-2")

    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    assert {:error, %Ash.Error.Forbidden{}} = send_to_key(first, 5, "Hello", "k-3")

    assert Rooms.get_key_thread!(@fleet, 5) == nil
  end

  test "an agent writes to a thread as the key it has a shard of" do
    runner = shard_agent("f", 7)

    posted = to_key!(runner, 1, "Hull survey started")

    assert {posted.as_key, posted.author_kind, posted.author_wallet} ==
             {7, :agent, wallet("f")}

    assert [%{agent_profile: %{name: "Runner"}}] = Rooms.read_key_thread!(@fleet, 1)
  end

  test "a key's own posts leave out its thread and come newest first",
       %{first: first, first_agent: first_agent, fifth_agent: fifth_agent} do
    post!(first_agent, "general", "Morning")
    post!(first_agent, "coding", "Hull survey started")
    to_key!(first, 5, "Welcome aboard")
    post!(fifth_agent, "general", "Hello")
    post!(first_agent, "general", "Anyone on the hull survey?")

    assert Enum.map(Rooms.posts_as_key!(@fleet, 1, actor: first), &{&1.room.slug, &1.body}) == [
             {"general", "Anyone on the hull survey?"},
             {"coding", "Hull survey started"},
             {"general", "Morning"}
           ]

    # Anyone else reads only what the key said in General.
    assert Enum.map(Rooms.posts_as_key!(@fleet, 1), &{&1.room.slug, &1.body}) == [
             {"general", "Anyone on the hull survey?"},
             {"general", "Morning"}
           ]

    assert Enum.map(Rooms.posts_as_key!(@fleet, 5), & &1.body) == ["Hello"]
    assert Rooms.posts_as_key!(@fleet, 7) == []

    for n <- 1..21, do: post!(first_agent, "general", "Post #{n}")
    assert [%{body: "Post 21"} | _rest] = latest = Rooms.posts_as_key!(@fleet, 1)
    assert length(latest) == 20
    assert length(Rooms.posts_as_key!(@fleet, 1, %{limit: 2})) == 2
  end

  test "a post tells the keys it concerns once, and a repeat tells nobody",
       %{first: first, fifth: fifth, first_agent: first_agent} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Rooms.fleet_topic(@fleet))

    {:ok, opening} = send_to_key(first, 5, "Welcome aboard", "k-1")
    assert_receive %Broadcast{event: "room_head", payload: %{room_id: room_id, seq: 1}}
    assert room_id == opening.room_id

    assert_receive %Broadcast{
      event: "key_activity",
      payload: %{fleet_id: @fleet, token_ids: [1, 5]}
    }

    {:ok, _answer} = send_to_key(fifth, 5, "Glad to be here", "k-2")
    assert_receive %Broadcast{event: "room_head", payload: %{room_id: ^room_id, seq: 2}}
    assert_receive %Broadcast{event: "key_activity", payload: %{token_ids: [5]}}
    refute_receive %Broadcast{event: "key_activity"}, 100

    {:ok, _again} = send_to_key(first, 5, "Welcome aboard", "k-1")
    refute_receive %Broadcast{}, 100

    post!(first_agent, "general", "Morning")
    assert_receive %Broadcast{event: "key_activity", payload: %{token_ids: [1]}}
    refute_receive %Broadcast{event: "key_activity"}, 100
  end

  test "the database keeps a thread's address to its key and never edits a thread's posts",
       %{first: first} do
    posted = to_key!(first, 5, "Welcome aboard")

    for {kind, slug, token_id} <- [
          {"key", "key-6", 5},
          {"key", "key-5", nil},
          {"created", "key-9", nil},
          {"created", "hull", 9}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind, token_id) " <>
                   "VALUES (gen_random_uuid(), $1, $2, 'Somewhere', $3, $4)",
                 [@fleet, slug, kind, token_id],
                 mode: :savepoint
               ),
             inspect({kind, slug, token_id})
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind, token_id) " <>
                 "VALUES (gen_random_uuid(), $1, 'key-5', 'Key 5', 'key', 5)",
               [@fleet],
               mode: :savepoint
             )

    for statement <- [
          "UPDATE keyfleet_app.messages SET as_key = 7 WHERE id = $1",
          "DELETE FROM keyfleet_app.messages WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(statement, [Ecto.UUID.dump!(posted.id)], mode: :savepoint)
    end

    assert {:error,
            %Postgrex.Error{postgres: %{code: :check_violation, constraint: "messages_as_key"}}} =
             Repo.query(
               "INSERT INTO keyfleet_app.messages " <>
                 "(seq, kind, in_key_thread, author_kind, author_wallet, as_key, body, body_digest, idempotency_key, fleet_id, room_id) " <>
                 "SELECT seq + 1, kind, in_key_thread, author_kind, author_wallet, NULL, body, body_digest, 'k-none', fleet_id, room_id " <>
                 "FROM keyfleet_app.messages WHERE id = $1",
               [Ecto.UUID.dump!(posted.id)],
               mode: :savepoint
             )

    assert Enum.map(Rooms.read_key_thread!(@fleet, 5), &{&1.id, &1.as_key}) == [{posted.id, 1}]
  end

  # The key after the highest one the fleet has recorded.
  defp unsold_key do
    {:ok, minted} = Keyfleet.Chain.minted(@fleet)
    minted + 1
  end

  defp to_key!(actor, token_id, body, opts \\ []) do
    {:ok, message} = send_to_key(actor, token_id, body, Ash.UUID.generate(), opts)
    message
  end

  defp send_to_key(actor, token_id, body, idempotency_key, opts \\ []) do
    %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: idempotency_key}
    |> Map.merge(Map.new(opts))
    |> Rooms.send_to_key(actor: actor)
  end

  defp post!(actor, slug, body) do
    {:ok, message} =
      Rooms.send_message(
        %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
        actor: actor
      )

    message
  end

  # An agent with a shard of key `token_id`.
  defp shard_agent(character, token_id) do
    runner = agent(character)
    Agents.ensure_profile!(%{name: "Runner", declared_harness: "local"}, actor: runner)
    ChainHelpers.issue_shard!(@fleet, token_id, runner.wallet_address)
    runner
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

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

  defp epoch!(token_id, owner_wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner_wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end
end
