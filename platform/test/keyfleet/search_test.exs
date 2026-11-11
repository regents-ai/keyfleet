defmodule Keyfleet.SearchTest do
  # A fleet's search finds what each reader may read and nothing else, and
  # pages through every match once, whatever the page size.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Dms
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Search
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    # Keys 1, 2 and 3 are sold, each to a different person.
    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}], do: epoch!(token_id, owner)
    :ok
  end

  test "each reader finds what they may read" do
    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "The deploy went out at noon")
    post!(writer, "coding", "Deployed the survey script to the hull")
    wall!(human("b"), 1, "Thanks for the deploy")
    dm!(human("a"), 1, 2, "The deploy key is in the vault")
    task = Workspace.create(@fleet, "task", %{"title" => "Deploying the probe"})
    Workspace.create(@fleet, "note", %{"title" => "Lunch", "body" => "Soup"})

    member = found(human("a"), "deploy")
    assert kinds(member) == %{"dm" => 1, "item" => 1, "post" => 3}
    assert Enum.find(member, &(&1.kind == "item")).id == task

    # Key 3's holder reads every room and the workspace, but not a message
    # between Keys 1 and 2.
    assert kinds(found(human("c"), "deploy")) == %{"item" => 1, "post" => 3}

    # Anyone else finds the Public room's post and the wall's, nothing more.
    outsider = found(human("z"), "deploy")
    assert kinds(outsider) == %{"post" => 2}
    assert Enum.all?(outsider, &(&1.room == nil or &1.room.slug == "general"))
    assert kinds(found(nil, "deploy")) == %{"post" => 2}
  end

  test "a post written as a muted Key, or taken off its wall, is left out" do
    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "Rotor check passed")
    wall!(human("b"), 3, "Rotor spares arrived")

    Rooms.mute_key!(@fleet, 1, actor: human("c"))
    assert [%{wall: 3}] = found(human("c"), "rotor")

    [%{id: removed}] = Enum.filter(found(human("c"), "rotor"), &(&1.wall == 3))
    Rooms.remove_from_wall!(@fleet, 3, removed, actor: human("c"))
    assert found(human("c"), "rotor") == []
    assert length(found(human("b"), "rotor")) == 1
  end

  test "pages hold every match once, newest first, at any page size" do
    writer = PairingHelpers.agent_for!(human("a"))

    for n <- 1..7, do: post!(writer, "general", "Hull reading #{n}")
    for n <- 1..5, do: dm!(human("a"), 1, 2, "Hull note #{n}")
    for n <- 1..4, do: Workspace.create(@fleet, "note", %{"title" => "Hull plate #{n}"})

    whole = walk(human("a"), "hull", 50)
    assert length(whole) == 16
    assert Enum.uniq_by(whole, &{&1.kind, &1.id}) == whole

    assert whole
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [newer, older] -> DateTime.compare(newer.at, older.at) != :lt end)

    for size <- [1, 3, 7], do: assert(walk(human("a"), "hull", size) == whole)
  end

  test "a query with no words in it, or too long, is refused" do
    for query <- ["   ", "hull\0", "-zz", "-a -b", ~s(-"a b"), "or -a"] do
      assert Search.page(@fleet, query, nil, human("a")) == {:error, :query}, inspect(query)
    end

    assert Search.page(@fleet, String.duplicate("a", Search.max_query() + 1), nil, human("a")) ==
             {:error, :query}

    assert {:ok, %{matches: [], cursor: nil}} = Search.page(@fleet, "the", nil, human("a"))
    assert {:ok, %{matches: []}} = Search.page(@fleet, "hull -zz", nil, human("a"))
  end

  defp found(actor, query) do
    {:ok, %{matches: matches}} = Search.page(@fleet, query, nil, 50, actor)
    matches
  end

  defp walk(actor, query, size, cursor \\ nil, pages \\ []) do
    {:ok, %{matches: matches, cursor: next}} = Search.page(@fleet, query, cursor, size, actor)
    pages = [matches | pages]

    if next,
      do: walk(actor, query, size, next, pages),
      else: pages |> Enum.reverse() |> Enum.concat()
  end

  defp kinds(matches), do: Enum.frequencies_by(matches, & &1.kind)

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

  defp dm!(actor, from, to, body) do
    Dms.send_dm!(
      %{
        fleet_id: @fleet,
        from_token_id: from,
        to_token_id: to,
        body: body,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  # Each person has their own account, so their mutes are their own.
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
