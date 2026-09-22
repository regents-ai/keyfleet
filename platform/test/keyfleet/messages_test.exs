defmodule KeyFleet.MessagesTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors
  alias KeyFleet.Agents
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Repo
  alias KeyFleet.Rooms

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @system %Actors.System{}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_core_rooms!()
    owner = human("a")
    epoch!(owner_wallet: wallet("a"))
    %{owner: owner}
  end

  test "each room counts its own posts from one upwards", %{owner: owner} do
    first = post!(owner, "general", "Morning")
    second = post!(owner, "general", "Anyone on the hull survey?")
    elsewhere = post!(owner, "work", "Hull survey started")

    assert Enum.map([first, second, elsewhere], & &1.seq) == [1, 2, 1]

    assert heads() == %{
             {@fleet, "general"} => 2,
             {@fleet, "work"} => 1,
             {@fleet, "planning"} => 0
           }
  end

  test "the same send key and the same words give back the one post", %{owner: owner} do
    {:ok, sent} = send_as(owner, "general", "Hull survey started", "k-1")
    {:ok, again} = send_as(owner, "general", "Hull survey started", "k-1")

    assert again.id == sent.id
    assert again.seq == sent.seq
    assert Enum.map(read("general"), & &1.id) == [sent.id]
    assert heads()[{@fleet, "general"}] == 1
  end

  test "the same send key with different words is refused and writes nothing", %{owner: owner} do
    {:ok, sent} = send_as(owner, "general", "Hull survey started", "k-1")

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.SendConflictError{}]}} =
             send_as(owner, "general", "Hull survey finished", "k-1")

    assert Enum.map(read("general"), & &1.id) == [sent.id]
    assert heads()[{@fleet, "general"}] == 1
  end

  test "a room the fleet does not have refuses the post", %{owner: owner} do
    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.RoomUnknownError{}]}} =
             send_as(owner, "hull-survey", "Anyone there?", "k-1")
  end

  test "only people holding a key of the fleet may post in it", %{owner: owner} do
    stranger = human("e")

    assert {:error, %Ash.Error.Forbidden{}} = send_as(stranger, "general", "Hello", "k-1")
    assert {:error, %Ash.Error.Forbidden{}} = send_as(nil, "general", "Hello", "k-2")

    assert {:error, %Ash.Error.Forbidden{}} =
             Rooms.send_message(
               %{
                 fleet_id: @other_fleet,
                 slug: "general",
                 body: "Hello",
                 idempotency_key: "k-3"
               },
               actor: owner
             )

    assert read("general") == []
    assert post!(owner, "general", "Hello").author_kind == :human
  end

  # Holding a key grants nothing while its ownership may be out of date.
  test "a key holder cannot post while key ownership is being refreshed", %{owner: owner} do
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(owner, "general", "Hello", "k-1")
    assert read("general") == []
  end

  test "an agent posts while it runs a key and stops when the key moves on" do
    agent = agent("c")
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Standing by", "k-1")

    request = Keys.request_pairing!(@fleet, 1, %{}, actor: agent)
    Keys.approve_pairing!(request, %{}, actor: human("a"))

    posted = post!(agent, "general", "Hull survey started", "k-2")
    assert posted.author_kind == :agent
    assert posted.author_wallet == wallet("c")
    assert posted.agent_profile_id == request.agent_profile_id

    epoch!(ownership_epoch: 1, owner_wallet: wallet("d"), log_index: 1)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Still here", "k-3")
    assert Enum.map(read("general"), & &1.id) == [posted.id]
  end

  test "a post can only answer a post in the same room", %{owner: owner} do
    elsewhere = post!(owner, "work", "Hull survey started")
    here = post!(owner, "general", "Morning")

    assert {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.ReplyOutsideRoomError{}]}} =
             Rooms.send_message(
               %{
                 fleet_id: @fleet,
                 slug: "general",
                 body: "On it",
                 idempotency_key: "k-2",
                 reply_to_id: elsewhere.id
               },
               actor: owner
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
        actor: owner
      )

    assert answer.reply_to_id == here.id
  end

  test "anyone may read a room, and a reader never gets more than it asked for", %{owner: owner} do
    for n <- 1..5, do: post!(owner, "general", "Post #{n}")

    assert Enum.map(read("general"), & &1.seq) == [1, 2, 3, 4, 5]
    assert Enum.map(read("general", %{after_seq: 3}), & &1.seq) == [4, 5]
    assert Enum.map(read("general", %{limit: 2}), & &1.seq) == [1, 2]

    assert {:error, %Ash.Error.Invalid{}} = Rooms.read_messages(@fleet, "general", %{limit: 201})
  end

  test "a reader behind on every room catches up on each post exactly once", %{owner: owner} do
    for n <- 1..3, do: post!(owner, "general", "General #{n}")
    post!(owner, "work", "Work 1")

    {:ok, first} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], owner)
    assert [%{slug: "general", head_seq: 3, cursor: 3, messages: caught_up}] = first.rooms
    assert first.proposals == []
    assert Enum.map(caught_up, & &1.seq) == [1, 2, 3]

    post!(owner, "general", "General 4")

    {:ok, second} =
      Rooms.sync(
        @fleet,
        [%{slug: "general", after_seq: 3}, %{slug: "work", after_seq: 1}],
        owner
      )

    assert [general, work] = second.rooms
    assert Enum.map(general.messages, & &1.seq) == [4]
    assert {general.cursor, general.head_seq} == {4, 4}
    assert {work.messages, work.cursor, work.head_seq} == {[], 1, 1}

    assert {:error, %Rooms.Errors.RoomUnknownError{}} =
             Rooms.sync(@fleet, [%{slug: "hull-survey", after_seq: 0}], owner)

    too_many = for n <- 1..101, do: %{slug: "general", after_seq: n}
    assert {:error, :invalid_request} = Rooms.sync(@fleet, too_many, owner)

    beyond = [%{slug: "general", after_seq: 2 ** 70}]
    assert {:error, :invalid_request} = Rooms.sync(@fleet, beyond, owner)

    twice = [%{slug: "general", after_seq: 0}, %{slug: "general", after_seq: 0}]
    assert {:error, :invalid_request} = Rooms.sync(@fleet, twice, owner)
  end

  test "a room's notice of a new post carries its place, and a repeat sends none", %{owner: owner} do
    Phoenix.PubSub.subscribe(KeyFleet.PubSub, Rooms.fleet_topic(@fleet))
    room = Rooms.get_room!(@fleet, "general")

    {:ok, sent} = send_as(owner, "general", "Hull survey started", "k-1")
    assert_receive {:room_head, room_id, 1}
    assert room_id == room.id
    assert sent.seq == 1

    {:ok, _again} = send_as(owner, "general", "Hull survey started", "k-1")
    refute_receive {:room_head, _room_id, _seq}, 100
  end

  test "the database refuses to edit, delete or empty posts, key ownership or pairings",
       %{owner: owner} do
    posted = post!(owner, "general", "Hull survey started")

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

    for table <- ~w(messages key_attachments key_pairings) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query("TRUNCATE keyfleet_app.#{table}", [], mode: :savepoint)
    end

    assert Enum.map(read("general"), &{&1.id, &1.body}) == [{posted.id, "Hull survey started"}]
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

  defp read(slug, params \\ %{}), do: Rooms.read_messages!(@fleet, slug, params)

  defp heads do
    @fleet
    |> Rooms.list_rooms!()
    |> Map.new(&{{&1.fleet_id, &1.slug}, &1.head_seq})
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp agent(character),
    do: %Actors.Agent{wallet_address: wallet(character), chain_id: 8453, audience: "keyfleet"}

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 0,
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
          String.duplicate(to_string(event.token_id), 32) <>
          String.duplicate(to_string(event.ownership_epoch), 32)
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
