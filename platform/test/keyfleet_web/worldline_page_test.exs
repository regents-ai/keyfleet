defmodule KeyfleetWeb.WorldlinePageTest do
  # A fleet's worldline reads what its reader may read of every source, in
  # time order, a page at a time back through time.
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [proposal!: 3]

  alias Keyfleet.{Actors, ChainHelpers, Dms, Fleets, Keys, PairingHelpers, Polls, Repo, Rooms}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.WorldlinePage

  @fleet "fleet_tech_classic"
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
    Workspace.open_log(@fleet)
    epoch!(1, "a")
    epoch!(2, "b")
    :ok
  end

  test "pages walk back through every source in time order, without a gap or a repeat" do
    # An hour ago and before: 140 posts turn about in two rooms, three to a
    # second, and six proposals opened and closed among them.
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)

    for n <- 0..139 do
      line!(
        if(rem(div(n, 7), 2) == 0, do: "general", else: "coding"),
        DateTime.add(hour_ago, -div(n, 3))
      )
    end

    for n <- 1..6 do
      proposal!(@fleet, n, %{
        opened_at: DateTime.add(hour_ago, -20 * n),
        closes_at: DateTime.add(hour_ago, -10 * n)
      })
    end

    for n <- 1..5, do: Workspace.create(@fleet, "task", %{"title" => "Plate #{n}"})

    pages = walk(3)
    events = pages |> Enum.reverse() |> Enum.concat()

    assert Enum.all?(pages, &(&1 != []))
    assert length(Enum.uniq_by(events, & &1.id)) == length(events)
    assert Enum.sort(ids(events)) == Enum.sort(ids(Enum.concat(walk(100))))

    assert Enum.frequencies_by(events, & &1.kind) == %{
             post: 140,
             proposal_opened: 6,
             proposal_closed: 6,
             change: 5
           }

    # Each page is oldest first, and every page reaches back from the one after it.
    for page <- pages, do: assert(page == Enum.sort_by(page, &{stamp(&1), &1.id}))

    for [newer, older] <- Enum.chunk_every(pages, 2, 1, :discard) do
      assert stamp(List.last(older)) <= stamp(hd(newer))
    end
  end

  test "a page reads at most its limit of each source, and later events stay out of older pages" do
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    for n <- 0..29, do: line!("general", DateTime.add(hour_ago, -n))

    for n <- 1..9 do
      proposal!(@fleet, n, %{opened_at: DateTime.add(hour_ago, -n), closes_at: hour_ago})
    end

    %{events: newest, cursor: cursor} = page(nil, limit: 4)

    assert cursor
    assert newest |> Enum.frequencies_by(& &1.kind) |> Map.values() |> Enum.max() <= 4

    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "After the first page")
    later = DateTime.add(DateTime.utc_now(), 1)
    proposal!(@fleet, 10, %{opened_at: later, closes_at: DateTime.add(later, 1)})

    older = walk(cursor, 4, [])
    all = [newest | older] |> Enum.reverse() |> Enum.concat()

    assert Enum.frequencies_by(all, & &1.kind) == %{
             post: 30,
             proposal_opened: 9,
             proposal_closed: 9
           }
  end

  test "a reader sees the rooms it reads and the workspace and polls only as a member, never a Key's thread or a message" do
    owner = human("a")
    writer = PairingHelpers.agent_for!(owner)
    post!(writer, "general", "For everyone")
    post!(writer, "people", "For people and agents")
    post!(writer, "coding", "For the Keys")

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 1, body: "Only for Key 1", idempotency_key: "k-1"},
      actor: owner
    )

    Dms.send_dm!(
      %{
        fleet_id: @fleet,
        from_token_id: 2,
        to_token_id: 1,
        body: "Just between us",
        idempotency_key: Ash.UUID.generate()
      },
      actor: human("b")
    )

    Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
    proposal!(@fleet, 1, %{})

    Polls.start_poll!(
      %{fleet_id: @fleet, question: "Which door next?", choices: ["Left", "Right"], minutes: 30},
      actor: owner
    )

    seen = fn actor ->
      %{events: events} = page(nil, actor: actor)
      Enum.map(events, &{&1.kind, &1.title})
    end

    member = seen.(owner)

    for event <- [
          {:post, "For everyone"},
          {:post, "For people and agents"},
          {:post, "For the Keys"},
          {:change, "Map the plates"},
          {:poll, "Which door next?"},
          {:proposal_opened, "Proposal 1"}
        ],
        do: assert(event in member)

    for actor <- [nil, human("e")] do
      assert Enum.sort(seen.(actor)) ==
               Enum.sort([
                 {:post, "For everyone"},
                 {:post, "For people and agents"},
                 {:proposal_opened, "Proposal 1"}
               ])
    end

    for actor <- [owner, human("b"), nil], {_kind, title} <- seen.(actor) do
      refute title in ["Only for Key 1", "Just between us"]
    end
  end

  # Every page back from the newest, `limit` of each source at a time, the
  # newest page first.
  defp walk(limit), do: walk(nil, limit, [])

  defp walk(cursor, limit, pages) do
    %{events: events, cursor: next} = page(cursor, limit: limit)
    pages = [events | pages]
    if next, do: walk(next, limit, pages), else: Enum.reverse(pages)
  end

  # A page as the holder of Key 1 reads it, unless `opts` names another reader.
  defp page(cursor, opts),
    do:
      WorldlinePage.page(
        @fleet,
        cursor,
        opts |> Keyword.put_new(:actor, human("a")) |> Keyword.put_new(:limit, 100)
      )

  defp ids(events), do: Enum.map(events, & &1.id)
  defp stamp(event), do: DateTime.to_unix(event.at, :microsecond)

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  # A post written at `at`, as Key 1's owner.
  defp line!(slug, at) do
    room = Rooms.get_room!(@fleet, slug, authorize?: false)
    body = "Line at #{DateTime.to_iso8601(at)}"

    Repo.insert_all(
      "messages",
      [
        %{
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          seq: System.unique_integer([:positive]),
          fleet_id: @fleet,
          room_id: Ecto.UUID.dump!(room.id),
          kind: "post",
          in_key_thread: false,
          author_kind: "human",
          author_wallet: wallet("a"),
          as_key: 1,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: DateTime.to_naive(at)
        }
      ],
      prefix: "keyfleet_app"
    )
  end

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet(owner),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}
end
