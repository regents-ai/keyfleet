defmodule KeyfleetWeb.ActivityLinesTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ActivityLines

  # Invariants covered:
  # - a page shows members' words as they wrote them, a quote without its
  #   link marks
  # - no line shows a character that can't be seen or reverses the text
  # - every line ends without a full stop, the way an activity list reads;
  #   a full stop a member wrote stays
  # - an item whose title has nothing to see still has words to link
  # - an item read without its title is named by its type, never linked
  # - a key's number is written the one way every page writes it, and a
  #   proposal is a part of its own, so a page can link it
  # - a wallet with no Key or agent to name it, or one Keys moved to, is a
  #   part of its own, so a page can show it as every address is shown

  @post %{
    id: "post:1",
    at: ~U[2026-09-25 12:00:00Z],
    kind: :post,
    facts: %{
      by: %{token_id: 7, agent: "Ada *bold*"},
      room: %{slug: "open-1", topic: "Hull [survey](x)", name: "Open 1"},
      excerpt: "Ship *v2* [now](https://example.com)"
    }
  }

  test "a quote on a page drops its link marks" do
    assert ActivityLines.text(@post) ==
             "Ada *bold* (Key 7) in Hull [survey](x): “Ship *v2* now”"
  end

  test "characters that can't be seen or reverse the text are shown nowhere" do
    post =
      put_in(@post.facts, %{
        by: %{token_id: 7, agent: "Ada\u202E"},
        room: %{slug: "open-1", topic: "Hull\u200B", name: "Open 1"},
        excerpt: "Ship\u2066 it\nnow\e[31m"
      })

    assert ActivityLines.text(post) == "Ada (Key 7) in Hull: “Ship it now[31m”"
  end

  test "an item whose title has nothing to see still has words to link" do
    goal = %{
      id: "created:1",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :created,
      facts: %{by: nil, item: %{id: "goal-1", type: "goal", title: "\u200B\u2066"}}
    }

    assert [{:item, "goal-1", title}] =
             for({:item, _, _} = item <- ActivityLines.parts(goal), do: item)

    assert title != ""
  end

  test "a wallet with no Key to name it is a part of its own, shown short" do
    wallet = "0x1234567890abcdef1234567890abcdef12345678"

    proposed = %{
      id: "proposed:1",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :proposed,
      facts: %{number: 1, proposer: %{token_id: nil, wallet: wallet}}
    }

    assert [{:address, ^wallet} | _] = ActivityLines.parts(proposed)
    assert ActivityLines.text(proposed) == "0x1234..5678 put Proposal 1 to a vote"
  end

  test "Keys moved to one wallet are one sentence, the wallet a part of its own" do
    wallet = "0x1234567890abcdef1234567890abcdef12345678"

    moved =
      &%{
        id: "transfer:1",
        at: ~U[2026-09-25 12:00:00Z],
        kind: :moved,
        facts: %{token_ids: &1, to: wallet}
      }

    assert {:address, wallet} in ActivityLines.parts(moved.([4]))
    assert ActivityLines.channel(moved.([4])) == :keys
    assert ActivityLines.text(moved.([4])) == "Key 4 moved to 0x1234..5678"
    assert ActivityLines.text(moved.([3, 4, 7])) == "Keys 3, 4 and 7 moved to 0x1234..5678"
    assert ActivityLines.text(moved.([4, 5, 6, 7])) == "Keys 4–7 moved to 0x1234..5678"

    assert ActivityLines.text(moved.([3, 4, 8, 12, 1_200])) ==
             "Keys 3, 4, 8 and 2 others moved to 0x1234..5678"
  end

  test "a dead end added to the workspace is told as one recorded" do
    dead_end = %{
      id: "created:2",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :created,
      facts: %{
        by: %{token_id: 7, agent: nil},
        item: %{id: "dead_end#4", type: "dead_end", title: "Scraping the forum"}
      }
    }

    assert ActivityLines.text(dead_end) == "Key 7 recorded a dead end: “Scraping the forum”"
  end

  test "an item read without its title is named by its type, with a capital to open on" do
    at = ~U[2026-09-25 12:00:00Z]
    finding = %{id: "finding#2", type: "finding", title: nil}
    evidence = %{id: "evidence#3", type: "evidence", title: nil}

    created = %{
      id: "created:3",
      at: at,
      kind: :created,
      facts: %{by: %{token_id: 7, agent: nil}, item: finding}
    }

    produced = %{
      id: "linked:1",
      at: at,
      kind: :linked,
      facts: %{by: nil, relation: "produces", source: evidence, target: finding}
    }

    assert ActivityLines.text(created) == "Key 7 reported a finding"
    assert ActivityLines.text(produced) == "Some evidence produced a finding"
    refute Enum.any?(ActivityLines.parts(produced), &match?({:item, _, _}, &1))
  end

  test "key numbers are grouped, and a proposal is a part a page can link" do
    at = ~U[2026-09-25 12:00:00Z]
    sale = %{id: "sale:1", at: at, kind: :sale, facts: %{token_ids: [1234]}}

    votes = %{
      id: "votes:1",
      at: at,
      kind: :votes,
      facts: %{
        number: 12,
        yes: %{count: 1, token_ids: [1234]},
        no: %{count: 0, token_ids: []},
        abstain: %{count: 0, token_ids: []}
      }
    }

    assert ActivityLines.text(sale) == "Key 1,234 was bought"
    assert {:proposal, 12} in ActivityLines.parts(votes)
    assert ActivityLines.text(votes) == "Key 1,234 voted yes on Proposal 12"
  end

  test "keys that abstained are said to have abstained" do
    facts = %{
      number: 12,
      yes: %{count: 0, token_ids: []},
      no: %{count: 1, token_ids: [5]},
      abstain: %{count: 2, token_ids: [3, 4]}
    }

    votes = %{id: "votes:1", at: ~U[2026-09-25 12:00:00Z], kind: :votes, facts: facts}

    assert ActivityLines.text(votes) ==
             "Key 5 voted no and Keys 3 and 4 abstained on Proposal 12"
  end

  test "a run of Keys bought and handed-out tasks are one sentence" do
    at = ~U[2026-09-25 12:00:00Z]
    by = %{token_id: 17, agent: nil}
    item = &%{id: "x:1", at: at, kind: &1, facts: &2}

    assert ActivityLines.text(item.(:sale, %{token_ids: [56, 57, 58]})) ==
             "Keys 56–58 were bought"

    assert ActivityLines.text(item.(:sale, %{token_ids: [56, 58]})) == "2 Keys were bought"

    tasks = &item.(:tasks, Map.merge(%{by: by, taken: 0, to: [4, 8], others: 0}, &1))

    assert ActivityLines.text(tasks.(%{added: 3, given: 0, to: []})) == "Key 17 added 3 tasks"

    assert ActivityLines.text(tasks.(%{added: 0, given: 2})) ==
             "Key 17 gave 2 tasks to Keys 4 and 8"

    assert ActivityLines.text(tasks.(%{added: 4, given: 1, to: [4]})) ==
             "Key 17 added 4 tasks and gave one to Key 4"

    assert ActivityLines.text(tasks.(%{added: 5, given: 5, to: [1, 2, 3], others: 2})) ==
             "Key 17 added 5 tasks and gave 5 to Keys 1, 2, 3 and 2 others"

    assert ActivityLines.text(tasks.(%{added: 1, taken: 1, given: 0})) ==
             "Key 17 added a task and took one on"

    assert ActivityLines.text(tasks.(%{added: 4, taken: 1, given: 2})) ==
             "Key 17 added 4 tasks, took one on and gave 2 to Keys 4 and 8"

    assert ActivityLines.text(tasks.(%{added: 0, taken: 2, given: 0})) ==
             "Key 17 took on 2 tasks"
  end

  test "a run of one change counts its items" do
    facts = %{by: %{token_id: 3, agent: "Scout"}, count: 4, type: "task"}
    item = &%{id: "changes:1", at: ~U[2026-09-25 12:00:00Z], kind: :changes, facts: &1}

    assert ActivityLines.text(item.(Map.put(facts, :change, :archived))) ==
             "Scout (Key 3) archived 4 tasks"

    assert ActivityLines.text(item.(Map.merge(facts, %{change: :submitted, type: "evidence"}))) ==
             "Scout (Key 3) submitted 4 pieces of evidence for review"
  end

  test "every line ends without a full stop, and a member's own full stop stays" do
    at = ~U[2026-09-25 12:00:00Z]
    key = %{token_id: 7, agent: nil}
    wallet = "0x1234567890abcdef1234567890abcdef12345678"
    task = %{id: "task#1", type: "task", title: "Map the hull"}
    finding = %{id: "finding#2", type: "finding", title: "Hull is sound", confidence: "high"}
    room = %{slug: "open-1", topic: nil, name: "Open 1"}
    none = %{count: 0, token_ids: []}

    facts = [
      post: %{by: key, room: room, excerpt: "Ship it."},
      posts: %{count: 3, room: room, keys: [key], others: 2, excerpt: "Ship it"},
      room_named: %{by: key, topic: "Hull"},
      tasks: %{by: key, added: 2, taken: 1, given: 1, to: [4], others: 0},
      created: %{by: key, item: finding},
      created: %{by: nil, item: %{task | title: nil}},
      claimed: %{by: key, to: key, item: task},
      claimed: %{by: key, to: %{token_id: 8, agent: nil}, item: task},
      unclaimed: %{item: task},
      submitted: %{by: key, item: task},
      reviewed: %{by: key, decision: "accept", item: task},
      reviewed: %{by: key, decision: "dispute", item: task},
      progress: %{by: key, item: task, progress: "doing"},
      status: %{by: key, item: task, status: "open"},
      status: %{by: key, item: task, status: "done"},
      revised: %{by: key, item: task},
      joined: %{by: key, item: task},
      left: %{by: key, item: task},
      archived: %{by: key, item: task},
      changes: %{by: key, change: :revised, count: 2, type: "task"},
      linked: %{by: key, relation: "supports", source: finding, target: task},
      linked: %{by: key, relation: "contradicts", source: finding, target: task},
      linked: %{by: nil, relation: "produces", source: task, target: finding},
      sale: %{token_ids: [150, 151, 152, 153]},
      given: %{token_ids: [5]},
      moved: %{token_ids: [68], to: wallet},
      shard_issued: %{agent: nil, wallet: wallet, token_id: 7, expires_at: at},
      shard_ended: %{stepped_down?: true, agent: %{name: "Scout"}, wallet: wallet, token_id: 7},
      shard_ended: %{stepped_down?: false, agent: nil, wallet: wallet, token_id: 7},
      proposed: %{number: 2, proposer: key},
      votes: %{number: 2, yes: %{count: 1, token_ids: [7]}, no: none, abstain: none},
      executed: %{number: 2}
    ]

    lines =
      for {kind, f} <- facts, do: ActivityLines.text(%{id: "x", at: at, kind: kind, facts: f})

    for line <- lines, do: refute(String.ends_with?(line, "."), line)

    assert "Key 7 in Open 1: “Ship it.”" in lines
    assert "Keys 150–153 were bought" in lines
    assert "Key 68 moved to 0x1234..5678" in lines
    assert "0x1234..5678 holds a shard of Key 7 until 25 September 2026" in lines
  end
end
