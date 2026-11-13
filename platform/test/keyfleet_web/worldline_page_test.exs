defmodule KeyfleetWeb.WorldlinePageTest do
  # A fleet's worldline reads what its reader may read of every source, in
  # time order, a page at a time back through time.
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers,
    only: [
      proposal!: 3,
      vote!: 5,
      execution!: 3,
      cancellation!: 3,
      presence!: 3,
      money_event!: 3
    ]

  alias Keyfleet.{
    Actors,
    ChainHelpers,
    Dms,
    Fleets,
    Keys,
    PairingHelpers,
    Polls,
    Projects,
    Repo,
    Rooms
  }

  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{KeyLinks, PollsLive, ProjectPage, ProposalsPage, WorldlinePage}

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

    # Besides them, Keys 1 and 2 bought, and the projects every fleet starts with.
    assert Enum.frequencies_by(events, & &1.kind) == %{
             post: 140,
             proposal_opened: 6,
             proposal_closed: 6,
             change: 5,
             sold: 2,
             project: 3
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

    older = walk(cursor, [limit: 4], [])
    all = [newest | older] |> Enum.reverse() |> Enum.concat()

    assert Enum.frequencies_by(all, & &1.kind) == %{
             post: 30,
             proposal_opened: 9,
             proposal_closed: 9,
             sold: 2,
             project: 3
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

    # Anyone else reads the public rooms and what the chain and the project
    # titles show everyone.
    for actor <- [nil, human("e")] do
      assert Enum.sort(seen.(actor)) ==
               Enum.sort([
                 {:post, "For everyone"},
                 {:post, "For people and agents"},
                 {:proposal_opened, "Proposal 1"},
                 {:sold, "Key 1 bought"},
                 {:sold, "Key 2 bought"},
                 {:project, "General"},
                 {:project, "Append-only scratchpad"},
                 {:project, "Keyfleet Classic #1 Collaborative Understanding"}
               ])
    end

    for actor <- [owner, human("b"), nil], {_kind, title} <- seen.(actor) do
      refute title in ["Only for Key 1", "Just between us"]
    end
  end

  test "a post's title is its words, without the Markdown marks it was written in" do
    writer = PairingHelpers.agent_for!(human("a"))

    for body <- [
          "### The Claude Code row for the cross-harness record\n\nThree runs agree.",
          "**Done:** the plates map is up",
          "See [the plates map](https://example.com/plates) before you start",
          "Run `mix test` before you push",
          "```elixir\nmix test\n```"
        ],
        do: post!(writer, "general", body)

    titles = for %{kind: :post, title: title} <- page(nil, []).events, do: title

    assert Enum.sort(titles) ==
             Enum.sort([
               "The Claude Code row for the cross-harness record\n\nThree runs agree.",
               "Done: the plates map is up",
               "See the plates map before you start",
               "Run mix test before you push",
               "elixir\nmix test"
             ])
  end

  test "every fleet action shows, each linking to the page it shows on" do
    owner = human("a")
    proposal!(@fleet, 1, %{opened_at: DateTime.add(DateTime.utc_now(), -7200)})
    proposal!(@fleet, 2, %{})
    vote!(@fleet, 1, wallet("a"), :yes, [2, 1])
    execution!(@fleet, 1, wallet("a"))
    cancellation!(@fleet, 2, wallet("f"))
    ChainHelpers.issue_shard!(@fleet, 1, wallet("c"))
    ChainHelpers.end_shard!(@fleet, 1, wallet("c"), wallet("c"))
    presence!(@fleet, 2, DateTime.utc_now())
    epoch!(2, "d", 2)
    money_event!(@fleet, :daily_split_run, voted: false, keys: 2, bps: 100)
    money_event!(@fleet, :claimed,
      account: wallet("a"),
      by: wallet("a"),
      asset: wallet("0"),
      amount: Decimal.new(5)
    )
    Projects.start_project!(@fleet, 1, "plates", "Hull plates", actor: owner)

    poll =
      Polls.start_poll!(
        %{fleet_id: @fleet, question: "Which door next?", choices: ["Left", "Right"], minutes: 30},
        actor: owner
      )

    Polls.end_poll!(poll, @fleet, actor: owner)

    shown = for event <- page(nil, []).events, into: %{}, do: {event.kind, event}
    key = &KeyLinks.page_path(@fleet, &1)
    proposal = &ProposalsPage.detail_path(@fleet, &1)

    for {kind, path} <- [
          vote: proposal.(1),
          executed: proposal.(1),
          cancelled: proposal.(2),
          shard_lent: key.(1),
          shard_ended: key.(1),
          present: key.(2),
          transfer: key.(2),
          daily_split: ProposalsPage.treasury_path(@fleet),
          claimed: ProposalsPage.treasury_path(@fleet),
          poll: PollsLive.poll_path(@fleet, poll.id),
          poll_stopped: PollsLive.poll_path(@fleet, poll.id),
          project: ProjectPage.path(@fleet, "plates")
        ] do
      assert %{trail: "line", path: ^path} = shown[kind], "#{kind} shows on #{path}"
    end

    # A vote is the lowest of its Keys'; a change of hands, the Key's.
    assert %{key: 1} = shown.vote
    assert %{key: 2} = shown.transfer
    assert %{key: 1} = shown.project
  end

  test "a filter keeps a Key's events, or a wallet's and those of the Keys it holds" do
    agent = PairingHelpers.agent_for!(human("a"))
    post!(agent, "general", "Key 1's agent writes")
    post!(PairingHelpers.agent_for!(human("b")), "general", "Key 2's agent writes")
    proposal!(@fleet, 1, %{author_key: 1, proposer: wallet("a")})
    proposal!(@fleet, 2, %{author_key: 2, proposer: wallet("b")})
    vote!(@fleet, 2, wallet("b"), :no, [2])
    presence!(@fleet, 1, DateTime.utc_now())
    ChainHelpers.issue_shard!(@fleet, 2, wallet("c"))
    # Key 1 changes hands, from wallet a to wallet d.
    epoch!(1, "d", 2)

    seen = fn by -> for event <- page(nil, by: by).events, do: event.title end

    key_1 = [
      "Key 1's agent writes",
      "Proposal 1",
      "Key 1 bought",
      "Key 1 changed hands",
      "Key 1 marked present"
    ]

    assert Enum.sort(seen.({:key, 1})) == Enum.sort(key_1)

    # Wallet d holds Key 1 now, so it has Key 1's events from before it did.
    assert Enum.sort(seen.({:wallet, wallet("d")})) == Enum.sort(key_1)

    # Wallet a held Key 1 and holds no Key now: only what it did itself,
    # its agent's posts written for it among them.
    assert Enum.sort(seen.({:wallet, wallet("a")})) ==
             ["Key 1 bought", "Key 1's agent writes", "Proposal 1"]

    # An agent's wallet, written in any case, has what the agent wrote.
    {:ok, by} = WorldlinePage.by(" 0X" <> String.upcase(String.slice(agent.wallet_address, 2..-1//1)))
    assert seen.(by) == ["Key 1's agent writes"]

    # A shard's wallet, and a Key nobody did anything as.
    assert seen.({:wallet, wallet("c")}) == ["Lent to 0xcccc..cccc"]
    assert seen.({:key, 9}) == []
  end

  test "pages under a filter walk back through only its events, without a gap or a repeat" do
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)

    for n <- 0..59,
        do: line!("general", DateTime.add(hour_ago, -n), if(rem(n, 2) == 0, do: 1, else: 2))

    pages = walk(4, by: {:key, 1})
    events = Enum.concat(pages)

    assert length(pages) > 1
    assert Enum.all?(pages, &(&1 != []))
    assert length(Enum.uniq_by(events, & &1.id)) == length(events)
    assert Enum.frequencies_by(events, & &1.kind) == %{post: 30, sold: 1}
    assert Enum.all?(events, &(&1.key == 1))
  end

  test "a filter's words name a Key by its number or a wallet in any case, and nothing else" do
    for words <- ["19", "Key 19", "key19", "#19", "Key #19", " 19 "],
        do: assert(WorldlinePage.by(words) == {:ok, {:key, 19}}, words)

    assert WorldlinePage.by("Key 1,234") == {:ok, {:key, 1234}}
    assert WorldlinePage.by("0x" <> String.duplicate("aB", 20)) ==
             {:ok, {:wallet, "0x" <> String.duplicate("ab", 20)}}
    assert WorldlinePage.by("  ") == {:ok, nil}

    for words <- ["0", "Key", "Key 0", "19a", "0x123", "0x" <> String.duplicate("g", 40), "Lamp"],
        do: assert(WorldlinePage.by(words) == :error, words)
  end

  # Every page back from the newest, `limit` of each source at a time, the
  # newest page first.
  defp walk(limit, opts \\ []), do: walk(nil, [limit: limit] ++ opts, [])

  defp walk(cursor, opts, pages) do
    %{events: events, cursor: next} = page(cursor, opts)
    pages = [events | pages]
    if next, do: walk(next, opts, pages), else: Enum.reverse(pages)
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

  # A post written at `at`, as Key `key`'s owner.
  defp line!(slug, at, key \\ 1) do
    room = Rooms.get_room!(@fleet, slug, authorize?: false)
    body = "Line at #{DateTime.to_iso8601(at)} as Key #{key}"

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
          author_wallet: wallet(if(key == 1, do: "a", else: "b")),
          as_key: key,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: DateTime.to_naive(at)
        }
      ],
      prefix: "keyfleet_app"
    )
  end

  defp epoch!(token_id, owner, epoch \\ 1) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: wallet(owner),
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <>
            Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{token_id}/#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}
end
