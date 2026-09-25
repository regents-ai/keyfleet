defmodule Keyfleet.MessagesTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

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
    Rooms.bootstrap_rooms!()
    owner = human("a")
    epoch!(owner_wallet: wallet("a"))
    %{owner: owner}
  end

  test "each room counts its own posts from one upwards", %{owner: owner} do
    first = post!(owner, "general", "Morning")
    second = post!(owner, "general", "Anyone on the hull survey?")
    elsewhere = post!(owner, "coding", "Hull survey started")

    assert Enum.map([first, second, elsewhere], & &1.seq) == [1, 2, 1]

    assert Map.reject(heads(), fn {_room, head} -> head == 0 end) == %{
             {@fleet, "general"} => 2,
             {@fleet, "coding"} => 1
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
    Keys.approve_pairing!(request, Keys.default_limits(), actor: human("a"))

    posted = post!(agent, "general", "Hull survey started", "k-2")
    assert posted.author_kind == :agent
    assert posted.author_wallet == wallet("c")
    assert posted.agent_profile_id == request.agent_profile_id

    epoch!(ownership_epoch: 2, owner_wallet: wallet("d"), log_index: 1)

    assert {:error, %Ash.Error.Forbidden{}} = send_as(agent, "general", "Still here", "k-3")
    assert Enum.map(read("general"), & &1.id) == [posted.id]
  end

  test "an agent's new post is its latest contribution; a repeat or a person's post is not",
       %{owner: owner} do
    agent = agent("c")

    profile =
      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)

    request = Keys.request_pairing!(@fleet, 1, %{}, actor: agent)
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)

    post!(agent, "general", "Hull survey started", "k-1")
    noted = Agents.get_check_in!(profile.id, @fleet)
    assert noted.last_contribution_kind == :post
    assert noted.last_check_in_at == noted.last_contribution_at

    # Long enough ago that a new post would be written down again.
    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_contribution_at = last_contribution_at - interval '2 minutes'"
    )

    post!(agent, "general", "Hull survey started", "k-1")
    post!(owner, "general", "Thanks", "k-2")

    assert [repeated] = Ash.read!(Agents.CheckIn)
    assert repeated.last_contribution_at == DateTime.add(noted.last_contribution_at, -2, :minute)
  end

  test "a post can only answer a post in the same room", %{owner: owner} do
    elsewhere = post!(owner, "coding", "Hull survey started")
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
    post!(owner, "coding", "Coding 1")

    {:ok, first} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], 0, 0, owner)
    assert [%{slug: "general", head_seq: 3, cursor: 3, messages: caught_up}] = first.rooms
    assert %{items: [], has_more: false} = first.proposals
    assert Enum.map(caught_up, & &1.seq) == [1, 2, 3]

    post!(owner, "general", "General 4")

    {:ok, second} =
      Rooms.sync(
        @fleet,
        [%{slug: "general", after_seq: 3}, %{slug: "coding", after_seq: 1}],
        0,
        0,
        owner
      )

    assert [general, coding] = second.rooms
    assert Enum.map(general.messages, & &1.seq) == [4]
    assert {general.cursor, general.head_seq} == {4, 4}
    assert {coding.messages, coding.cursor, coding.head_seq} == {[], 1, 1}

    assert {:error, %Rooms.Errors.RoomUnknownError{}} =
             Rooms.sync(@fleet, [%{slug: "hull-survey", after_seq: 0}], 0, 0, owner)

    too_many = for n <- 1..101, do: %{slug: "general", after_seq: n}
    assert {:error, :invalid_request} = Rooms.sync(@fleet, too_many, 0, 0, owner)

    beyond = [%{slug: "general", after_seq: 2 ** 70}]
    assert {:error, :invalid_request} = Rooms.sync(@fleet, beyond, 0, 0, owner)

    twice = [%{slug: "general", after_seq: 0}, %{slug: "general", after_seq: 0}]
    assert {:error, :invalid_request} = Rooms.sync(@fleet, twice, 0, 0, owner)

    for after_seq <- [-1, 2 ** 70] do
      assert {:error, :invalid_request} =
               Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], after_seq, 0, owner)

      assert {:error, :invalid_request} =
               Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], 0, after_seq, owner)
    end
  end

  test "a reader behind in a room is asked back at once, even when the workspace is read up",
       %{owner: owner} do
    for n <- 1..51, do: post!(owner, "general", "Post #{n}")

    {:ok, synced} = Rooms.sync(@fleet, [%{slug: "general", after_seq: 0}], 0, 0, owner)
    assert [%{cursor: 50, head_seq: 51}] = synced.rooms
    assert synced.graph.has_more == false
    assert synced.next_poll_seconds == 0
  end

  test "a room's notice of a new post carries its place, and a repeat sends none", %{owner: owner} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Rooms.fleet_topic(@fleet))
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

  test "the database holds only posts and room namings", %{owner: owner} do
    posted = post!(owner, "general", "Hull survey started")

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

  test "a person always writes as the highest-ranked key their wallets hold, from its wallet" do
    epoch!(token_id: 7, owner_wallet: wallet("b"))
    epoch!(token_id: 30, owner_wallet: wallet("c"))
    person = %Actors.Human{human_account_id: 2, wallet_addresses: [wallet("c"), wallet("b")]}

    first = post!(person, "general", "Morning")
    assert {first.as_key, first.author_wallet} == {7, wallet("b")}

    # Selling key 7 makes key 30 their highest-ranked key.
    epoch!(token_id: 7, ownership_epoch: 2, owner_wallet: wallet("e"), log_index: 1)

    second = post!(person, "general", "Still here")
    assert {second.as_key, second.author_wallet} == {30, wallet("c")}

    assert Enum.map(read("general"), &{&1.seq, &1.as_key}) == [{1, 7}, {2, 30}]
  end

  test "an agent writes as the highest-ranked key it runs today", %{owner: owner} do
    agent = agent("f")
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: agent)

    for token_id <- [40, 12] do
      epoch!(token_id: token_id)
      request = Keys.request_pairing!(@fleet, token_id, %{}, actor: agent)
      Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
    end

    first = post!(agent, "general", "Hull survey started")
    assert {first.as_key, first.author_wallet, first.author_kind} == {12, wallet("f"), :agent}

    # Key 12 changes hands, which ends the agent running it.
    epoch!(token_id: 12, ownership_epoch: 2, owner_wallet: wallet("e"), log_index: 1)

    assert post!(agent, "general", "Still surveying").as_key == 40
  end

  test "a repeated send key answers with the key the post was first written as", %{owner: owner} do
    {:ok, sent} = send_as(owner, "general", "Hull survey started", "k-1")
    epoch!(token_id: 1, ownership_epoch: 2, owner_wallet: wallet("b"), log_index: 1)
    epoch!(token_id: 2, owner_wallet: wallet("a"))

    {:ok, again} = send_as(owner, "general", "Hull survey started", "k-1")
    assert {again.id, again.as_key} == {sent.id, 1}
  end

  test "a person's retry is known whichever of their wallets now holds the key they write as" do
    epoch!(token_id: 7, owner_wallet: wallet("b"))
    epoch!(token_id: 30, owner_wallet: wallet("c"))
    person = %Actors.Human{human_account_id: 2, wallet_addresses: [wallet("b"), wallet("c")]}

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
    seller = %Actors.Human{human_account_id: 1, wallet_addresses: [seller_wallet]}
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

  test "naming an open room is written as the namer's key", %{owner: owner} do
    {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: owner)

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
