defmodule KeyfleetWeb.MentionsJourneyTest do
  # A Key asked something with `@Key N` hears it in its agent's next sync,
  # once, from the rooms and walls its reader may read, and never from itself
  # or from a Key it muted.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    # Keys 1, 2 and 3 are sold, each to a different person.
    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}], do: epoch!(token_id, owner)

    %{
      a: PairingHelpers.agent_for!(human("a")),
      b: PairingHelpers.agent_for!(human("b")),
      c: PairingHelpers.agent_for!(human("c"))
    }
  end

  test "Key 2 hears each mention of it once, read on from its cursor", %{a: a, b: b, c: c} do
    asked = post!(a, "general", "@Key 2 can you check the hull?")
    post!(a, "general", "Nobody asked here")
    post!(b, "general", "@Key2 a note to myself")
    Rooms.mute_key!(@fleet, 3, actor: b)
    post!(c, "general", "@key 2 from a Key you muted")

    first = sync!(b, nil)
    assert first.yours.as_key == 2

    assert %{posts: [mention], has_more: false, next_cursor: cursor} = first.yours.mentions
    assert is_binary(cursor)

    assert %{id: id, room: "general", wall: nil, seq: seq, as_key: 1} = mention
    assert id == asked.id and seq == asked.seq
    assert mention.excerpt == "@Key 2 can you check the hull?"

    # Read on from the cursor, nothing is answered twice.
    assert %{posts: [], next_cursor: ^cursor, has_more: false} = sync!(b, cursor).yours.mentions

    wall_post = wall!(a, 3, "@Key 2 and @Key 3, the spares came")

    assert %{posts: [%{id: id, wall: 3, room: nil}], next_cursor: next} =
             sync!(b, cursor).yours.mentions

    assert id == wall_post.id and next != cursor

    # Key 3's own agent hears the wall post too, but not its own post.
    assert [%{id: ^id}] = sync!(c, nil).yours.mentions.posts
  end

  test "more than a page waits past the cursor, and every mention comes once", %{a: a, b: b} do
    posted = for n <- 1..25, do: post!(a, "general", "@Key 2 reading #{n}").id

    first = sync!(b, nil).yours.mentions
    assert first.has_more and length(first.posts) == 20

    second = sync!(b, first.next_cursor).yours.mentions
    refute second.has_more
    assert Enum.map(first.posts ++ second.posts, & &1.id) == posted
  end

  test "a reader is never shown a mention in a room it cannot read", %{a: a} do
    post!(a, "coding", "@Key 2 the members' plan")
    public = post!(a, "general", "@Key 2 in public")
    on_wall = wall!(a, 2, "@Key 2 on your wall")

    # The fleet's members read every room; anyone else the Public room and the walls.
    assert {:ok, %{posts: member}} = Rooms.mention_changes(@fleet, 2, nil, human("c"))
    assert length(member) == 3

    assert {:ok, %{posts: outsider}} = Rooms.mention_changes(@fleet, 2, nil, human("z"))
    assert Enum.map(outsider, & &1.id) == [public.id, on_wall.id]
  end

  test "a cursor no sync answered is refused", %{b: b} do
    assert {:error, %Ash.Error.Invalid{}} =
             tool(b, %{mentions: %{after: "not a cursor"}})
  end

  defp sync!(agent, cursor) do
    {:ok, answer} = tool(agent, %{mentions: %{after: cursor}})
    answer
  end

  defp tool(agent, input) do
    KeyfleetWeb.AgentTools.Rooms
    |> Ash.ActionInput.for_action(
      :sync,
      Map.merge(
        %{
          fleet_id: @fleet,
          rooms: [],
          graph: %{after_seq: 0},
          proposals: %{after_seq: 0},
          run: %{kind: "session"}
        },
        input
      ),
      actor: agent,
      context: %{waiter: nil}
    )
    |> Ash.run_action()
  end

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp wall!(actor, token_id, body) do
    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{
      human_account_id: :binary.first(character),
      wallet_addresses: [wallet(character)]
    }

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet(owner),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/1"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end
