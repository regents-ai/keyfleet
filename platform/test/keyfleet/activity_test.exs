defmodule Keyfleet.ActivityTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers,
    only: [proposal!: 3, vote!: 5, execution!: 3]

  alias Keyfleet.Activity
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}
  # The wallet the workspace fixtures sign every change with.
  @member_wallet "0x" <> String.duplicate("a1", 20)
  # The workspace fixtures log their changes from 2026-09-22 12:00, a minute
  # apart: a day on is within the week, eight days on is not.
  @this_week ~U[2026-09-23 12:00:00Z]
  @week_on ~U[2026-09-30 13:00:00Z]

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
    # Chain records are stamped with the time the reader saw them: in a test,
    # the time its transaction began, the same for every one.
    %{seen_at: epoch!(1, 1, "a").observed_at}
  end

  describe "paging" do
    test "walking the pages gives every item of every source once, in one read's order",
         %{seen_at: seen_at} do
      owner = human("a")
      Enum.each(2..4, &epoch!(&1, 1, "a"))
      epoch!(2, 2, "b")

      proposal!(@fleet, 1, %{})
      vote!(@fleet, 1, wallet("a"), :yes, [1, 3])
      vote!(@fleet, 1, wallet("b"), :no, [2])
      proposal!(@fleet, 2, %{})
      execution!(@fleet, 2, wallet("f"))
      proposal!(@fleet, 3, %{})

      post!(owner, "general", "Morning")
      post!(owner, "general", "Hull survey started")
      post!(owner, "coding", "Pushed the survey script")
      {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: owner)
      # Lines, links and changes at the very time the chain records were seen.
      line!("business", seen_at)
      line!("voting", seen_at)

      runner = agent("c")
      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: runner)
      ChainHelpers.issue_shard!(@fleet, 3, wallet("c"))
      ChainHelpers.end_shard!(@fleet, 3, wallet("c"), wallet("a"))

      goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      task = Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
      Workspace.edit(@fleet, task, %{"assignee_key" => 1})
      Workspace.link(@fleet, task, goal, "supports")

      graph_event_at!(seen_at, "object.created", %{
        "object" => %{"id" => "note#9", "type" => "note"}
      })

      %{items: items, cursor: nil} = page(nil)

      assert Enum.map(items, & &1.kind) |> Enum.frequencies() == %{
               proposed: 3,
               votes: 1,
               executed: 1,
               sale: 1,
               transfer: 1,
               shard_issued: 1,
               shard_ended: 1,
               created: 3,
               claimed: 1,
               linked: 1,
               posts: 1,
               post: 3,
               room_named: 1
             }

      assert newest_first?(items)

      for limit <- [1, 2, 3, 4, 7] do
        assert walk(limit) == items
      end
    end

    test "long runs of posts, sales and votes page without a gap or a repeat", %{seen_at: seen_at} do
      # 230 lines in turns of nine per room, three to a second, so the 200
      # lines read at once end partway through a turn.
      for n <- 0..229 do
        line!(
          if(rem(div(n, 9), 2) == 0, do: "general", else: "coding"),
          DateTime.add(seen_at, -div(n, 3))
        )
      end

      Enum.each(2..120, &epoch!(&1, 1, "a"))
      # More votes than are read at once, all newer than both proposals.
      proposal!(@fleet, 1, %{})
      proposal!(@fleet, 2, %{})
      Enum.each(1..120, &vote!(@fleet, 2, wallet("a"), :yes, [&1]))

      items = walk(30)

      assert items == walk(7)
      assert items == walk(1)
      assert length(Enum.uniq_by(items, & &1.id)) == length(items)
      assert newest_first?(items)

      assert sum(items, [:post], fn _facts -> 1 end) + sum(items, [:posts], & &1.count) == 230
      assert sum(items, [:sale], &length(&1.token_ids)) == 120
      assert sum(items, [:votes], & &1.yes.count) == 120
      assert sum(items, [:proposed], & &1.number) == 3
    end

    test "a page ends short when one source needs a third read, and no run of posts splits",
         %{seen_at: seen_at} do
      # Twelve runs of 45 posts, turn about in two rooms, a second apart. A
      # read of 200 posts ends 20 posts into its fifth run.
      for n <- 0..539 do
        line!(
          if(rem(div(n, 45), 2) == 0, do: "general", else: "coding"),
          DateTime.add(seen_at, -(n + 1))
        )
      end

      %{items: first, cursor: cursor} = page(nil)

      # Two reads hand over four runs each; the ninth run needs a third read.
      assert Enum.map(first, &{&1.kind, &1.facts[:count]}) ==
               [{:sale, nil} | List.duplicate({:posts, 45}, 8)]

      assert cursor

      items = walk(30)
      assert Enum.take(items, 9) == first

      assert Enum.map(items, &{&1.kind, &1.facts[:count]}) ==
               [{:sale, nil} | List.duplicate({:posts, 45}, 12)]
    end

    test "what happens after the first page is read stays out of the pages after it" do
      owner = human("a")
      Enum.each(2..3, &epoch!(&1, 1, "a"))
      post!(owner, "general", "Morning")
      post!(owner, "coding", "Pushed the survey script")
      Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
      proposal!(@fleet, 1, %{})
      ChainHelpers.issue_shard!(@fleet, 2, wallet("c"))

      # The newest item, a change the workspace logged ahead of this server's
      # clock, fills the first page: every other source is still to be read.
      ahead = DateTime.add(DateTime.utc_now(), 1, :hour)

      graph_event_at!(ahead, "object.created", %{
        "object" => %{"id" => "note#90", "type" => "note"}
      })

      whole = walk(1)
      %{items: [%{at: ^ahead}] = first, cursor: cursor} = page(nil, limit: 1)

      # One of everything, each newer than the first page by place or time.
      Workspace.create(@fleet, "note", %{"title" => "Plates"})
      post!(owner, "general", "Survey done")
      ChainHelpers.end_shard!(@fleet, 2, wallet("c"), wallet("c"))
      epoch!(4, 1, "a")
      epoch!(2, 2, "b")
      proposal!(@fleet, 2, %{})
      vote!(@fleet, 2, wallet("a"), :yes, [1])
      ChainHelpers.issue_shard!(@fleet, 3, wallet("d"))

      assert walk(cursor, 1, [first]) == whole
      assert length(page(nil).items) > length(whole)
    end
  end

  test "key threads and word edits stay out; claims, progress and links show; only goal titles are public" do
    owner = human("a")

    ada = %Actors.Agent{
      wallet_address: @member_wallet,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(%{name: "Ada", declared_harness: "test"}, actor: ada)

    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: 1, body: "Only for key 1", idempotency_key: "k-1"},
      actor: owner
    )

    post!(owner, "general", "For everyone")

    note = Workspace.create(@fleet, "note", %{"title" => "Plates", "body" => "First pass"})
    task = Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
    finding = Workspace.create(@fleet, "finding", %{"title" => "Rust", "statement" => "Some"})
    goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
    Workspace.edit(@fleet, note, %{"body" => "Second pass"})
    Workspace.edit(@fleet, task, %{"title" => "Map every plate"})
    Workspace.edit(@fleet, finding, %{"statement" => "More than we thought"})
    link = Workspace.link(@fleet, finding, goal, "relates_to")
    Workspace.unlink(@fleet, link)
    Workspace.attention(@fleet, "stale", task)
    Workspace.edit(@fleet, task, %{"assignee_key" => 17})
    Workspace.edit(@fleet, task, %{"progress" => "done"})
    Workspace.link(@fleet, finding, goal, "contradicts")

    %{items: items} = Activity.page(@fleet, nil, actor: owner)

    assert [%{kind: :post, facts: %{excerpt: "For everyone", room: %{slug: "general"}}}] =
             Enum.filter(items, &(&1.kind in [:post, :posts]))

    by = %{token_id: 17, agent: "Ada"}

    assert items |> Enum.filter(&String.starts_with?(&1.id, "graph:")) |> Enum.map(& &1.facts) ==
             [
               %{
                 by: by,
                 relation: "contradicts",
                 source: %{id: finding, type: "finding", title: "Rust", confidence: "low"},
                 target: %{id: goal, type: "goal", title: "Survey the hull"}
               },
               %{
                 by: by,
                 item: %{id: task, type: "task", title: "Map every plate"},
                 progress: "done"
               },
               %{
                 by: by,
                 item: %{id: task, type: "task", title: "Map every plate"},
                 to: %{token_id: 17, agent: nil}
               },
               %{by: by, item: %{id: goal, type: "goal", title: "Survey the hull"}},
               %{by: by, item: %{id: finding, type: "finding", title: "Rust", confidence: "low"}},
               %{by: by, item: %{id: task, type: "task", title: "Map every plate"}},
               %{by: by, item: %{id: note, type: "note", title: "Plates"}}
             ]

    # Anyone else reads the goal by its title and every other item by its type.
    %{items: items} = Activity.page(@fleet, nil)

    assert items |> Enum.filter(&String.starts_with?(&1.id, "graph:")) |> Enum.map(& &1.facts) ==
             [
               %{
                 by: by,
                 relation: "contradicts",
                 source: %{id: finding, type: "finding", title: nil},
                 target: %{id: goal, type: "goal", title: "Survey the hull"}
               },
               %{by: by, item: %{id: task, type: "task", title: nil}, progress: "done"},
               %{
                 by: by,
                 item: %{id: task, type: "task", title: nil},
                 to: %{token_id: 17, agent: nil}
               },
               %{by: by, item: %{id: goal, type: "goal", title: "Survey the hull"}},
               %{by: by, item: %{id: finding, type: "finding", title: nil}},
               %{by: by, item: %{id: task, type: "task", title: nil}},
               %{by: by, item: %{id: note, type: "note", title: nil}}
             ]
  end

  test "posts group by room while they come within the hour", %{seen_at: seen_at} do
    at = &DateTime.add(seen_at, -&1, :minute)
    Enum.each(200..196//-1, &line!("general", at.(&1)))
    line!("coding", at.(190))
    Enum.each([185, 184], &line!("general", at.(&1)))
    # An hour and a minute after the one before splits the room's posts.
    line!("general", at.(123))
    line!("general", at.(62))

    %{items: items} = page(nil)

    assert Enum.map(items, &{&1.kind, &1.facts[:room][:slug], Map.get(&1.facts, :count, 1)}) ==
             chain_opening() ++
               [
                 {:post, "general", 1},
                 {:post, "general", 1},
                 {:posts, "general", 2},
                 {:post, "coding", 1},
                 {:posts, "general", 5}
               ]
  end

  test "someone holding none of the fleet's keys sees only General's posts" do
    owner = human("a")
    post!(owner, "general", "For everyone")
    post!(owner, "coding", "For the keys")

    for actor <- [nil, human("e")] do
      assert [%{facts: %{excerpt: "For everyone", room: %{slug: "general"}}}] =
               for(%{kind: :post} = item <- page(nil, actor: actor).items, do: item)
    end
  end

  # A key's mint is its first ownership epoch, 1, and each transfer adds one.
  test "a key bought and then passed on is one sale and one change of hands" do
    epoch!(1, 2, "b")

    %{items: items} = page(nil)

    assert for(%{kind: kind} = item <- items, kind in [:sale, :transfer], do: {kind, item.facts}) ==
             [{:transfer, %{token_id: 1}}, {:sale, %{token_ids: [1]}}]
  end

  test "keys that abstained are counted apart from those that voted yes or no" do
    proposal!(@fleet, 1, %{})
    vote!(@fleet, 1, wallet("a"), :yes, [1, 2])
    vote!(@fleet, 1, wallet("a"), :no, [3])
    vote!(@fleet, 1, wallet("a"), :abstain, [4, 5])

    %{items: items} = page(nil)

    assert [%{number: 1, yes: yes, no: no, abstain: abstain}] =
             for(%{kind: :votes, facts: facts} <- items, do: facts)

    assert {yes, no, abstain} ==
             {%{count: 2, token_ids: [1, 2]}, %{count: 1, token_ids: [3]},
              %{count: 2, token_ids: [4, 5]}}
  end

  describe "headline" do
    test "a contradiction from the last week comes before a later post", %{seen_at: seen_at} do
      goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      finding = Workspace.create(@fleet, "finding", %{"title" => "Rust"})
      Workspace.link(@fleet, finding, goal, "contradicts")
      line!("general", ~U[2026-09-22 18:00:00Z])

      now = ~U[2026-09-23 12:00:00Z]
      assert %{kind: :linked, facts: %{relation: "contradicts"}} = Activity.headline(@fleet, now)

      # A week on, the contradiction is old news and no rule features anything.
      assert Activity.headline(@fleet, DateTime.add(seen_at, 8, :day)) == nil
    end

    test "a task done this week comes before an open question, and not after a week" do
      goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      Workspace.edit(@fleet, goal, %{"open_questions" => ["Where does the rust start?"]})
      task = Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
      Workspace.edit(@fleet, task, %{"progress" => "done"})

      assert %{kind: :progress, facts: %{item: %{id: ^task}, progress: "done"}} =
               Activity.headline(@fleet, @this_week)

      assert %{
               kind: :open_question,
               facts: %{
                 goal: %{id: ^goal, title: "Survey the hull"},
                 question: "Where does the rust start?"
               }
             } = Activity.headline(@fleet, @week_on)
    end

    test "a goal achieved this week is featured" do
      goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      Workspace.edit(@fleet, goal, %{"status" => "achieved"})

      assert %{kind: :status, facts: %{item: %{id: ^goal}, status: "achieved"}} =
               Activity.headline(@fleet, @this_week)
    end

    test "finished work and a proposal carried out: the newer is featured", %{seen_at: seen_at} do
      task = Workspace.create(@fleet, "task", %{"title" => "Map the plates"})
      proposal!(@fleet, 1, %{})
      # Carried out at the time the chain records were seen.
      execution!(@fleet, 1, wallet("f"))
      post!(human("a"), "general", "Paid")
      now = DateTime.add(seen_at, 1, :hour)

      graph_event_at!(DateTime.add(seen_at, -1, :minute), "patch.applied", done(task))
      assert %{kind: :executed, facts: %{number: 1}} = Activity.headline(@fleet, now)
      # A week on, neither counts.
      assert Activity.headline(@fleet, DateTime.add(now, 7, :day)) == nil

      graph_event_at!(DateTime.add(seen_at, 1, :minute), "patch.applied", done(task))
      assert %{kind: :progress, facts: %{item: %{id: ^task}}} = Activity.headline(@fleet, now)
    end

    test "the open question is the first of the most recently changed open goal" do
      older = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      Workspace.create(@fleet, "goal", %{"title" => "Paint", "open_questions" => ["Which red?"]})
      Workspace.edit(@fleet, older, %{"open_questions" => ["Where?", "When?"]})

      # Goals that are no longer open do not count, however recent.
      for {title, change} <- [
            {"Dock", &Workspace.edit(@fleet, &1, %{"status" => "achieved"})},
            {"Sail", &Workspace.edit(@fleet, &1, %{"status" => "dropped"})},
            {"Moor", &Workspace.archive(@fleet, &1)}
          ] do
        @fleet
        |> Workspace.create("goal", %{"title" => title, "open_questions" => ["Why?"]})
        |> change.()
      end

      assert %{kind: :open_question, facts: %{goal: %{id: ^older}, question: "Where?"}} =
               Activity.headline(@fleet, @week_on)
    end

    test "when the newest open goal has no question, no rule features anything" do
      Workspace.create(@fleet, "goal", %{"title" => "Paint", "open_questions" => ["Which red?"]})
      Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})

      assert Activity.headline(@fleet, @week_on) == nil
    end

    test "a contradiction behind the latest 200 notable changes is not featured" do
      goal = Workspace.create(@fleet, "goal", %{"title" => "Survey the hull"})
      finding = Workspace.create(@fleet, "finding", %{"title" => "Rust"})
      Workspace.link(@fleet, finding, goal, "contradicts")

      notes!(199, ~U[2026-09-22 18:00:00Z])
      assert %{kind: :linked} = Activity.headline(@fleet, @this_week)

      notes!(1, ~U[2026-09-22 18:00:00Z])
      assert Activity.headline(@fleet, @this_week) == nil
    end
  end

  test "a shard issued and ended names its agent, and whether the agent stepped down" do
    epoch!(2, 1, "a")
    runner = agent("c")
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "test"}, actor: runner)
    issued = ChainHelpers.issue_shard!(@fleet, 1, wallet("c"))
    ChainHelpers.issue_shard!(@fleet, 2, wallet("d"))
    ChainHelpers.end_shard!(@fleet, 1, wallet("c"), wallet("c"))
    ChainHelpers.end_shard!(@fleet, 2, wallet("d"), wallet("a"))

    shards =
      for %{kind: kind, facts: facts} <- page(nil).items,
          kind in [:shard_issued, :shard_ended],
          do: {kind, facts.token_id, facts.agent && facts.agent.name, facts[:stepped_down?]}

    assert shards == [
             {:shard_ended, 2, nil, false},
             {:shard_ended, 1, "Orbit runner", true},
             {:shard_issued, 2, nil, nil},
             {:shard_issued, 1, "Orbit runner", nil}
           ]

    assert [%{expires_at: expires_at}] =
             for(
               %{kind: :shard_issued, facts: %{token_id: 1} = facts} <-
                 page(nil).items,
               do: facts
             )

    assert expires_at == issued.expires_at
  end

  # Every page from the newest, `limit` items each, joined.
  defp walk(limit), do: walk(nil, limit, [])

  defp walk(cursor, limit, pages) do
    %{items: items, cursor: next} = page(cursor, limit: limit)
    assert length(items) in 1..limit
    pages = [items | pages]
    if next, do: walk(next, limit, pages), else: pages |> Enum.reverse() |> Enum.concat()
  end

  defp newest_first?(items) do
    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [newer, older] -> DateTime.compare(newer.at, older.at) != :lt end)
  end

  defp sum(items, kinds, count) do
    items |> Enum.filter(&(&1.kind in kinds)) |> Enum.map(&count.(&1.facts)) |> Enum.sum()
  end

  # What the setup's one key sale reads as.
  defp chain_opening, do: [{:sale, nil, 1}]

  # A page as read by the holder of key 1, who reads every room.
  defp page(cursor, opts \\ []),
    do: Activity.page(@fleet, cursor, Keyword.put_new(opts, :actor, human("a")))

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  # A post written at `at`, as key 1's owner.
  defp line!(slug, at) do
    room = Rooms.get_room!(@fleet, slug)
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

  # A workspace event logged at `at`.
  defp graph_event_at!(at, type, payload) do
    cursor = Graph.get_cursor!(@fleet, actor: @system)
    seq = cursor.applied_seq + 1

    Graph.record_events!(
      [
        %{
          fleet_id: @fleet,
          seq: seq,
          event_id: "evt_#{seq}",
          type: type,
          actor: "member:8453:0x#{String.duplicate("b2", 20)}:17@3/agent:#{@member_wallet}",
          timestamp: DateTime.to_iso8601(at),
          payload: payload
        }
      ],
      actor: @system
    )

    Graph.advance_cursor!(cursor, %{applied_seq: seq}, actor: @system)
  end

  # A member's patch marking `task` done.
  defp done(task),
    do: %{"target" => task, "diff" => %{"progress" => %{"old" => "doing", "new" => "done"}}}

  # `count` new notes, logged at `at`.
  defp notes!(count, at) do
    cursor = Graph.get_cursor!(@fleet, actor: @system)
    seqs = Enum.map(1..count, &(cursor.applied_seq + &1))

    seqs
    |> Enum.map(fn seq ->
      %{
        fleet_id: @fleet,
        seq: seq,
        event_id: "evt_#{seq}",
        type: "object.created",
        actor: "keyfleet:gateway",
        timestamp: DateTime.to_iso8601(at),
        payload: %{"object" => %{"id" => "note##{seq}", "type" => "note"}}
      }
    end)
    |> Graph.record_events!(actor: @system)

    Graph.advance_cursor!(cursor, %{applied_seq: List.last(seqs)}, actor: @system)
  end

  defp epoch!(token_id, ownership_epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: ownership_epoch,
        owner_wallet: wallet(owner),
        block_number: 10 + ownership_epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <>
            Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{token_id}/#{ownership_epoch}"),
              case: :lower
            ),
        log_index: 0
      },
      actor: @system
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp agent(character),
    do: %Actors.Agent{
      wallet_address: wallet(character),
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }
end
