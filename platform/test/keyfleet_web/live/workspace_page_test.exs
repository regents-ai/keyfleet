defmodule KeyfleetWeb.Live.WorkspacePageTest do
  use KeyfleetWeb.ConnCase, async: false

  import Keyfleet.WorkspaceFixtures

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  @other "fibonacci_cascade"
  # A fleet whose name sorts after this one's.
  @later "fleet_tech_classic"
  @too_far 9_223_372_036_854_775_808
  @board "/app/fleets/fibonacci_syndicate/workspace"
  @notice "Every Key holder can read this. Never put passwords or private data here."
  @holder "0x" <> String.duplicate("d", 40)

  # The fleet is recorded as deployed, because a fleet still coming soon
  # has no workspace to show. Each page is read by the owner of one of its
  # Keys, as only a Key holder reads the workspace.
  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @holder,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    %{conn: signed_in_as(conn, @holder), visitor: conn}
  end

  describe "the fleet's items" do
    setup do
      open_log(@fleet)
      :ok
    end

    test "every kind of item shows as a card with what matters about it", %{conn: conn} do
      goal =
        create(@fleet, "goal", %{
          "title" => "Revenue",
          "outcome" => "One paying customer.",
          "status" => "open"
        })

      task =
        create(@fleet, "task", %{
          "title" => "Draft the brief",
          "progress" => "doing",
          "assignee_key" => 42,
          "next_step" => "Write the summary."
        })

      finding =
        create(@fleet, "finding", %{
          "title" => "Funds read briefs",
          "statement" => "They do.",
          "confidence" => "high"
        })

      evidence =
        create(@fleet, "evidence", %{
          "title" => "Interview",
          "source_uri" => "https://example.com/interview",
          "excerpt" => "We read every brief."
        })

      service =
        create(
          @fleet,
          "service",
          %{
            "title" => "Weekly briefs",
            "customer" => "Funds",
            "problem" => "Too many filings.",
            "price_proposal" => "250",
            "payment_asset" => "USDC"
          },
          by: 5
        )

      note = create(@fleet, "note", %{"title" => "Standup", "body" => "Ship it."})

      dead_end =
        create(@fleet, "dead_end", %{
          "title" => "Scraping the forum",
          "what_was_tried" => "Paged through the archive.",
          "why_it_failed" => "It needs a login."
        })

      {:ok, view, html} = live(conn, @board)

      assert html =~ @notice

      assert has_element?(
               view,
               ~s(.workspace-kicker a[href="/app/fleets/#{@fleet}"]),
               "Syndicate #1"
             )

      assert cards(view) == [dead_end, note, service, evidence, finding, task, goal]

      assert card_text(view, goal) =~ "Goal"
      assert {"Status", "Open"} in facts(view, goal)
      assert card_text(view, goal) =~ "One paying customer."
      assert {"Progress", "In progress"} in facts(view, task)
      assert {"Taken by", "Key 42"} in facts(view, task)
      assert has_element?(view, ~s(#{card(task)} a[href="/app/keys/#{@fleet}/42"]), "Key 42")
      assert card_text(view, task) =~ "Write the summary."
      assert facts(view, finding) == [{"Confidence", "High"}]
      assert card_text(view, evidence) =~ "We read every brief."

      assert has_element?(
               view,
               ~s(#{card(evidence)} a[href="https://example.com/interview"][rel="noopener noreferrer nofollow ugc"])
             )

      assert facts(view, service) == [{"Customer", "Funds"}, {"Proposed price", "250 USDC"}]
      assert card_text(view, note) =~ "Ship it."
      assert card_text(view, dead_end) =~ "Dead end"
      assert card_text(view, dead_end) =~ "It needs a login."

      # Who added each item, as the site names keys, and when it last changed.
      assert has_element?(view, ~s(#{card(service)} a[href="/app/keys/#{@fleet}/5"]), "Key 5")
      assert card_text(view, note) =~ "Added by Key 17"
      assert card_text(view, note) =~ "Last changed 22 September 2026 at 12:11 UTC"

      assert has_element?(
               view,
               ~s(#{card(task)} h3 a[href="#{@board}/task%23#{id_number(task)}"]),
               "Draft the brief"
             )

      edit(@fleet, service, %{"payment_asset" => "FLEET_TOKEN"})
      {:ok, view, _html} = live(conn, @board)

      assert {"Proposed price", "250 in the fleet’s own token"} in facts(view, service)
    end

    test "a card shows when it last changed, and changing it brings it to the top", %{conn: conn} do
      first = create(@fleet, "task", %{"title" => "First", "progress" => "todo"})
      second = create(@fleet, "note", %{"title" => "Second", "body" => "b"})
      edit(@fleet, first, %{"progress" => "done"}, by: 9)

      {:ok, view, _html} = live(conn, @board)

      assert cards(view) == [first, second]
      assert facts(view, first) == [{"Progress", "Done"}, {"Taken by", "No one yet"}]
      assert card_text(view, first) =~ "Last changed 22 September 2026 at 12:05 UTC"
      assert card_text(view, first) =~ "Added by Key 17"
    end

    test "an item kept to one level says which level", %{conn: conn} do
      level =
        create(@fleet, "task", %{"title" => "Level work", "progress" => "todo"}, scope: "level:3")

      fleet_wide = create(@fleet, "task", %{"title" => "Fleet work", "progress" => "todo"})

      {:ok, view, _html} = live(conn, @board)

      assert has_element?(view, ~s(#{card(level)} [data-level="3"]), "Level 3")
      refute has_element?(view, ~s(#{card(fleet_wide)} [data-level]))

      {:ok, item, _html} = live(conn, item_path(level))
      assert has_element?(item, ~s(#workspace-item-page [data-level="3"]), "Level 3")
    end

    test "archived items are hidden until asked for", %{conn: conn} do
      kept = create(@fleet, "note", %{"title" => "Kept", "body" => "b"})
      gone = create(@fleet, "note", %{"title" => "Gone", "body" => "b"})
      archive(@fleet, gone)

      {:ok, view, _html} = live(conn, @board)
      assert cards(view) == [kept]
      assert has_element?(view, "#workspace-archived-toggle", "Show archived items")

      view |> element("#workspace-archived-toggle") |> render_click()
      assert_patch(view, @board <> "?archived=shown")
      assert cards(view) == [gone, kept]
      assert has_element?(view, ~s(#{card(gone)} .workspace-badge), "Archived")
      refute has_element?(view, ~s(#{card(kept)} .workspace-badge))

      view |> element("#workspace-archived-toggle", "Hide archived items") |> render_click()
      assert_patch(view, @board)
      assert cards(view) == [kept]

      {:ok, item, _html} = live(conn, item_path(gone))
      assert has_element?(item, "#workspace-item-page .workspace-badge", "Archived")
    end

    test "one kind of item at a time", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "A task", "progress" => "todo"})
      create(@fleet, "note", %{"title" => "A note", "body" => "b"})
      archived = create(@fleet, "task", %{"title" => "Old task", "progress" => "done"})
      archive(@fleet, archived)

      {:ok, view, _html} = live(conn, @board)

      view |> element(~s([data-type-filter="task"])) |> render_click()
      assert_patch(view, @board <> "?type=task")
      assert cards(view) == [task]
      assert has_element?(view, ~s([data-type-filter="task"][aria-current="page"]))

      view |> element("#workspace-archived-toggle") |> render_click()
      assert_patch(view, @board <> "?type=task&archived=shown")
      assert cards(view) == [archived, task]

      view |> element(~s([data-type-filter="goal"])) |> render_click()
      assert cards(view) == []
      assert has_element?(view, "#workspace-empty", "No goals yet.")

      view |> element(~s([data-type-filter="dead_end"])) |> render_click()
      assert has_element?(view, "#workspace-empty", "No dead ends yet.")

      view |> element(~s([data-type-filter="all"])) |> render_click()
      assert length(cards(view)) == 3
    end

    test "items come twenty-four to a page", %{conn: conn} do
      ids = for n <- 1..30, do: create(@fleet, "note", %{"title" => "Note #{n}", "body" => "b"})
      newest_first = Enum.reverse(ids)

      {:ok, view, _html} = live(conn, @board)

      assert cards(view) == Enum.take(newest_first, 24)
      refute has_element?(view, "#workspace-previous")

      view |> element("#workspace-next") |> render_click()
      assert cards(view) == Enum.drop(newest_first, 24)
      refute has_element?(view, "#workspace-next")

      view |> element("#workspace-previous") |> render_click()
      assert cards(view) == Enum.take(newest_first, 24)
      refute has_element?(view, "#workspace-previous")
      assert has_element?(view, "#workspace-next")
    end

    test "a page name the workspace can't answer is a page that doesn't exist", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "A task", "progress" => "todo"})

      for path <- [
            @board <> "?type=person",
            @board <> "?archived=yes",
            @board <> "?after=nonsense",
            @board <> "?before=nonsense",
            item_path(task) <> "?links=nonsense",
            item_path(task) <> "?history=nonsense",
            "/app/fleets/#{@fleet}/workspace/task%231%232",
            "/app/fleets/#{@fleet}/workspace/rel_1"
          ] do
        assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, path) end
      end
    end

    test "a page position past anything the log can hold is a page that doesn't exist", %{
      conn: conn
    } do
      task = create(@fleet, "task", %{"title" => "A task", "progress" => "todo"})
      goal = create(@fleet, "goal", %{"title" => "A goal", "outcome" => "o"})
      link(@fleet, task, goal, "implements")

      for path <- [
            @board <> "?" <> URI.encode_query(after: keyset([@too_far, @fleet, task])),
            @board <> "?" <> URI.encode_query(before: keyset([@too_far, @fleet, task])),
            item_path(task) <> "?" <> URI.encode_query(links: keyset([@too_far, @fleet, "rel_5"])),
            item_path(task) <> "?history=#{@too_far}",
            item_path(task) <> "?history=99999999999999999999"
          ] do
        assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, path) end
      end
    end

    test "a page past the last one offers the way back", %{conn: conn} do
      note = create(@fleet, "note", %{"title" => "Only", "body" => "b"})
      past_it = keyset([1, @fleet, note])

      {:ok, view, _html} = live(conn, @board <> "?" <> URI.encode_query(after: past_it))

      assert cards(view) == []
      assert has_element?(view, "p", "There is nothing more here.")
      assert has_element?(view, ~s(#workspace-first-page[href="#{@board}"]))

      view |> element("#workspace-first-page") |> render_click()
      assert cards(view) == [note]
    end

    test "an empty workspace says so", %{conn: conn} do
      {:ok, view, html} = live(conn, @board)

      assert html =~ @notice

      assert has_element?(
               view,
               "#workspace-empty",
               "Nothing has been added to this workspace yet."
             )

      assert html =~ "Nothing has changed here yet."
      refute has_element?(view, "#workspace-cards")
    end

    test "an item that isn't in the workspace says so", %{conn: conn} do
      {:ok, view, html} = live(conn, "/app/fleets/#{@fleet}/workspace/task%23999")

      assert html =~ @notice
      assert has_element?(view, "h2", "This item isn’t in the workspace.")
    end

    test "nothing on the pages writes", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "A task", "progress" => "todo"})
      {:ok, board, _html} = live(conn, @board)
      {:ok, item, _html} = live(conn, item_path(task))

      for view <- [board, item] do
        page = workspace(view)
        html = LazyHTML.to_html(page)
        assert html =~ "A task"
        refute html =~ "<form"
        refute html =~ "phx-submit"

        # The board's Code panel copies its address and asks for a git
        # password, and neither writes the workspace; nothing else is pressed.
        assert Enum.count(LazyHTML.query(page, "button")) ==
                 Enum.count(LazyHTML.query(page, "#workspace-code button"))

        assert page |> LazyHTML.query("[phx-click]") |> LazyHTML.attribute("phx-click") ==
                 if(view == board, do: ["get_code_password"], else: [])
      end
    end
  end

  describe "an item's page" do
    setup do
      open_log(@fleet)
      :ok
    end

    test "shows every field, its links both ways, its history and where it was discussed", %{
      conn: conn
    } do
      Keyfleet.Repo.query!(
        "UPDATE keyfleet_app.rooms SET topic = 'Hull survey', topic_set_by = $1, " <>
          "topic_set_at = now() WHERE fleet_id = $2 AND slug = 'open-2'",
        ["0x" <> String.duplicate("a", 40), @fleet]
      )

      Keyfleet.Rooms.create_room!(%{fleet_id: @fleet, slug: "ship-ops", name: "Ship ops"},
        authorize?: false
      )

      goal =
        create(@fleet, "goal", %{
          "title" => "Revenue",
          "outcome" => "One paying customer.",
          "status" => "open"
        })

      task =
        create(@fleet, "task", %{
          "title" => "Draft the brief",
          "progress" => "todo",
          "deliverable" => "A weekly brief.",
          "result_ref" => "git+https://example.com/repo.git",
          "extra_notes" => "Anything else.",
          "discussion" => [
            %{"room" => "business", "seq" => 4},
            %{"room" => "open-2", "seq" => 1},
            %{"room" => "ship-ops", "seq" => 3},
            %{"room" => "elsewhere", "seq" => 2}
          ]
        })

      finding =
        create(@fleet, "finding", %{
          "title" => "Funds read briefs",
          "statement" => "They do.",
          "confidence" => "low"
        })

      delivers = link(@fleet, task, goal, "implements")
      supports = link(@fleet, finding, task, "supports")
      edit(@fleet, task, %{"progress" => "doing", "assignee_key" => 42}, by: 9)

      {:ok, view, html} = live(conn, item_path(task))

      assert html =~ @notice
      assert has_element?(view, "h1", "Draft the brief")

      assert has_element?(
               view,
               ~s(#workspace-item-page a[href="#{@board}"]),
               "Syndicate #1 workspace"
             )

      fields =
        view
        |> workspace()
        |> LazyHTML.query("#workspace-fields dt")
        |> Enum.map(&LazyHTML.text/1)

      assert fields == ["Progress", "Taken by", "Deliverable", "Result", "Extra notes"]
      assert has_element?(view, "#workspace-fields", "In progress")
      assert has_element?(view, ~s(#workspace-fields a[href="/app/keys/#{@fleet}/42"]), "Key 42")

      assert has_element?(
               view,
               ~s(#workspace-fields a[href="git+https://example.com/repo.git"][rel="noopener noreferrer nofollow ugc"])
             )

      assert has_element?(view, "#workspace-fields", "Anything else.")

      assert has_element?(
               view,
               ~s(#workspace-links [data-relation="#{delivers}"][data-direction="from"]),
               "This task delivers on"
             )

      assert has_element?(
               view,
               ~s(#workspace-links [data-relation="#{delivers}"] a[href="#{item_path(goal)}"]),
               "Revenue"
             )

      assert has_element?(
               view,
               ~s(#workspace-links [data-relation="#{supports}"][data-direction="to"]),
               "supports this task"
             )

      assert has_element?(
               view,
               ~s(#workspace-links [data-relation="#{supports}"] a[href="#{item_path(finding)}"]),
               "Funds read briefs"
             )

      assert history(view) == [
               "Key 9 updated “Draft the brief”: progress is now in progress, now taken by Key 42.",
               "Key 17 linked “Funds read briefs” to “Draft the brief”, which it supports.",
               "Key 17 linked “Draft the brief” to “Revenue”, which it delivers on.",
               "Key 17 added the task “Draft the brief”."
             ]

      assert has_element?(
               view,
               ~s(#workspace-discussion a[href="/app/fleets/#{@fleet}/rooms/business"]),
               "Message 4 in Business"
             )

      # An open room goes by the name its members gave it.
      assert has_element?(
               view,
               ~s(#workspace-discussion a[href="/app/fleets/#{@fleet}/rooms/open-2"]),
               "Message 1 in Hull survey"
             )

      # So does a room an agent created.
      assert has_element?(
               view,
               ~s(#workspace-discussion a[href="/app/fleets/#{@fleet}/rooms/ship-ops"]),
               "Message 3 in Ship ops"
             )

      assert has_element?(view, "#workspace-discussion span", "Message 2 in elsewhere")
      refute has_element?(view, ~s(#workspace-discussion a[href*="elsewhere"]))

      {:ok, goal_view, _html} = live(conn, item_path(goal))

      assert has_element?(
               goal_view,
               ~s(#workspace-links [data-relation="#{delivers}"][data-direction="to"]),
               "delivers on this goal"
             )

      assert has_element?(goal_view, "p", "No room messages point here yet.")
    end

    test "a dead end says what was tried and why it didn't work, and the task it came from",
         %{conn: conn} do
      task =
        create(@fleet, "task", %{"title" => "Find the forum's members", "progress" => "doing"})

      dead_end =
        create(@fleet, "dead_end", %{
          "title" => "Scraping the forum",
          "what_was_tried" => "Paged through the archive.",
          "why_it_failed" => "It needs a login."
        })

      produced = link(@fleet, task, dead_end, "produces")

      {:ok, view, _html} = live(conn, item_path(dead_end))

      assert has_element?(view, "h1", "Scraping the forum")

      fields =
        view
        |> workspace()
        |> LazyHTML.query("#workspace-fields div")
        |> Enum.map(fn field ->
          {field |> LazyHTML.query("dt") |> LazyHTML.text(),
           field |> LazyHTML.query("dd") |> LazyHTML.text() |> squish()}
        end)

      assert fields == [
               {"What was tried", "Paged through the archive."},
               {"Why it didn’t work", "It needs a login."}
             ]

      assert has_element?(
               view,
               ~s(#workspace-links [data-relation="#{produced}"][data-direction="to"]),
               "produces this dead end"
             )

      assert history(view) == [
               "Key 17 linked “Find the forum's members” to “Scraping the forum”, which it produces.",
               "Key 17 added the dead end “Scraping the forum”."
             ]
    end

    test "a removed link leaves the page and stays in its history", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "todo"})
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      relation = link(@fleet, task, goal, "implements")
      unlink(@fleet, relation, by: 8)

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(view, "p", "Nothing is linked to this yet.")

      assert history(view) == [
               "Key 8 unlinked “Draft” from “Revenue”, which it no longer delivers on.",
               "Key 17 linked “Draft” to “Revenue”, which it delivers on.",
               "Key 17 added the goal “Revenue”."
             ]
    end

    test "links and history come fifty at a time", %{conn: conn} do
      hub = create(@fleet, "goal", %{"title" => "Hub", "outcome" => "o", "status" => "open"})

      tasks =
        for n <- 1..52 do
          task = create(@fleet, "task", %{"title" => "Task #{n}", "progress" => "todo"})
          link(@fleet, task, hub, "implements")
          task
        end

      {:ok, view, _html} = live(conn, item_path(hub))

      assert linked(view) == Enum.take(tasks, 50)
      assert length(history(view)) == 50
      assert history(view) |> hd() =~ "Task 52"

      view |> element("#workspace-more-links") |> render_click()
      assert linked(view) == Enum.drop(tasks, 50)
      refute has_element?(view, "#workspace-more-links")
      # The history stays where it was while the links move on.
      assert history(view) |> hd() =~ "Task 52"

      view |> element("#workspace-more-history") |> render_click()

      assert history(view) == [
               "Key 17 linked “Task 2” to “Hub”, which it delivers on.",
               "Key 17 linked “Task 1” to “Hub”, which it delivers on.",
               "Key 17 added the goal “Hub”."
             ]

      refute has_element?(view, "#workspace-more-history")
      assert linked(view) == Enum.drop(tasks, 50)

      # Going back to the start of one leaves the other where it is.
      view |> element("#workspace-first-links") |> render_click()
      assert linked(view) == Enum.take(tasks, 50)
      assert length(history(view)) == 3

      view |> element("#workspace-more-links") |> render_click()
      view |> element("#workspace-latest-history") |> render_click()
      assert history(view) |> hd() =~ "Task 52"
      assert linked(view) == Enum.drop(tasks, 50)
    end

    test "a page of links or history past the last one says so and offers the way back", %{
      conn: conn
    } do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "todo"})
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o"})
      relation = link(@fleet, task, goal, "implements")
      "rel_" <> seq = relation
      past = keyset([String.to_integer(seq), @fleet, relation])

      {:ok, view, _html} =
        live(conn, item_path(task) <> "?" <> URI.encode_query(history: 0, links: past))

      assert linked(view) == []
      assert has_element?(view, "p", "There are no more links.")
      assert history(view) == []
      assert has_element?(view, "p", "There are no earlier changes.")

      view |> element("#workspace-first-links") |> render_click()
      assert linked(view) == [goal]
      assert history(view) == []

      view |> element("#workspace-latest-history") |> render_click()
      assert length(history(view)) == 2
      assert linked(view) == [goal]
    end
  end

  describe "the latest changes" do
    setup do
      open_log(@fleet)
      :ok
    end

    test "each change is one plain line, newest first", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "todo"})
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      relation = link(@fleet, task, goal, "implements", by: 3)
      edit(@fleet, task, %{"progress" => "done", "next_step" => "Send it."}, by: 4)
      edit(@fleet, task, %{"assignee_key" => nil})
      edit(@fleet, goal, %{"title" => "More revenue"})
      unlink(@fleet, relation)
      archive(@fleet, goal, by: 5)
      attention(@fleet, "task_unblocked", task)
      attention(@fleet, "needs_review", goal)
      attention(@fleet, "needs_review", "finding#999")
      attention(@fleet, "overdue", task)
      event(@fleet, "keyfleet.something_new", %{"anything" => [1, 2]})
      event(@fleet, "object.created", %{"unexpected" => true})

      {:ok, view, _html} = live(conn, @board)

      assert activity(view) == [
               "The workspace changed.",
               "The workspace changed.",
               "Something in the workspace needs attention.",
               "An item needs review.",
               "“More revenue” needs review.",
               "“Draft” is ready to start.",
               "Key 5 archived “More revenue”.",
               "Key 17 unlinked “Draft” from “More revenue”, which it no longer delivers on.",
               "Key 17 updated “More revenue”: title.",
               "Key 17 updated “Draft”: now taken by no one.",
               "Key 4 updated “Draft”: progress is now done, next step.",
               "Key 3 linked “Draft” to “More revenue”, which it delivers on.",
               "Key 17 added the goal “More revenue”.",
               "Key 17 added the task “Draft”."
             ]

      assert has_element?(view, ~s(#workspace-activity a[href="/app/keys/#{@fleet}/5"]), "Key 5")
      assert has_element?(view, ~s(#workspace-activity a[href="#{item_path(task)}"]), "Draft")
    end

    test "a change to what the workspace keeps about an item names no field of it", %{
      conn: conn
    } do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "todo"})
      [%{sys: sys}] = Graph.read_objects!(@fleet, [task], actor: %Actors.System{})

      event(@fleet, "patch.applied", %{
        "target" => task,
        "diff" => %{"sys" => %{"old" => sys, "new" => Map.put(sys, "scope", "level:2")}}
      })

      event(@fleet, "patch.applied", %{
        "target" => task,
        "diff" => %{
          "progress" => %{"old" => "todo", "new" => "blocked"},
          "sys" => %{"old" => sys, "new" => sys}
        }
      })

      {:ok, view, _html} = live(conn, @board)

      assert Enum.take(activity(view), 2) == [
               "Keyfleet updated “Draft”: progress is now blocked.",
               "Keyfleet updated “Draft”."
             ]

      assert has_element?(view, "#workspace-activity .workspace-detail", "at 12:05 UTC")
    end

    test "a change made by Keyfleet itself names no key", %{conn: conn} do
      event(@fleet, "keyfleet.something_new", %{}, "keyfleet:gateway")
      note = create(@fleet, "note", %{"title" => "N", "body" => "b"})

      Graph.record_events!(
        [
          %{
            fleet_id: @fleet,
            seq: 100,
            event_id: "evt_100",
            type: "patch.applied",
            actor: "keyfleet:gateway",
            timestamp: "2026-09-22T14:00:00Z",
            payload: %{"target" => note, "diff" => %{"body" => %{"old" => "b", "new" => "c"}}}
          }
        ],
        actor: %Keyfleet.Actors.System{}
      )

      {:ok, view, _html} = live(conn, @board)
      assert hd(activity(view)) == "Keyfleet updated “N”: note."
    end

    test "the latest thirty changes are shown", %{conn: conn} do
      for n <- 1..35, do: create(@fleet, "note", %{"title" => "Note #{n}", "body" => "b"})

      {:ok, view, _html} = live(conn, @board)

      lines = activity(view)
      assert length(lines) == 30
      assert hd(lines) == "Key 17 added the note “Note 35”."
      assert List.last(lines) == "Key 17 added the note “Note 6”."
    end

    test "a change elsewhere shows up without the reader doing anything", %{conn: conn} do
      open_log(@other)
      {:ok, view, _html} = live(conn, @board)
      watch_reads(view)
      assert cards(view) == []

      task = create(@fleet, "task", %{"title" => "New work", "progress" => "todo"})
      create(@other, "note", %{"title" => "Other fleet", "body" => "b"})

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@other),
        {:graph_head, @other, "log_fixture", 2}
      )

      # A notice about a fleet the page has since left changes nothing either.
      send(view.pid, {:graph_head, @other, "log_fixture", 2})
      refute_receive :workspace_read, 1_300

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fixture", 2}
      )

      assert_receive :workspace_read, 2_000
      assert cards(view) == [task]
      assert hd(activity(view)) == "Key 17 added the task “New work”."
      refute render(view) =~ "Other fleet"

      {:ok, item, _html} = live(conn, item_path(task))
      watch_reads(item)
      edit(@fleet, task, %{"progress" => "doing"})

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fixture", 4}
      )

      assert_receive :workspace_read, 2_000
      assert has_element?(item, "#workspace-fields", "In progress")
      assert hd(history(item)) == "Key 17 updated “New work”: progress is now in progress."
    end

    test "a burst of changes is read once, a moment later, and old news not at all", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @board)
      watch_reads(view)
      task = create(@fleet, "task", %{"title" => "New work", "progress" => "todo"})

      for watermark <- [1, 2, 2] do
        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Graph.head_topic(@fleet),
          {:graph_head, @fleet, "log_fixture", watermark}
        )
      end

      refute_receive :workspace_read, 600
      assert_receive :workspace_read, 1_000
      refute_receive :workspace_read, 1_300
      assert cards(view) == [task]

      # What the page has already read, or less, is not read again.
      for watermark <- [2, 1] do
        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Graph.head_topic(@fleet),
          {:graph_head, @fleet, "log_fixture", watermark}
        )
      end

      refute_receive :workspace_read, 1_300

      # A copy of a fresh log is read however far along it is.
      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fresh", 1}
      )

      assert_receive :workspace_read, 2_000
    end
  end

  describe "another fleet's workspace" do
    test "never shows up in this one", %{conn: conn} do
      open_log(@fleet)
      open_log(@other)
      ours = create(@fleet, "task", %{"title" => "Ours", "progress" => "todo"}, id: "task#1")
      create(@other, "task", %{"title" => "Theirs", "progress" => "done"}, id: "task#1")

      create(@other, "goal", %{"title" => "Their goal", "outcome" => "o", "status" => "open"},
        id: "goal#7"
      )

      link(@other, "task#1", "goal#7", "implements")
      edit(@other, "task#1", %{"title" => "Theirs changed"})
      archive(@other, "goal#7")
      attention(@other, "needs_review", "task#1")

      {:ok, board, _html} = live(conn, @board <> "?archived=shown")
      assert cards(board) == [ours]
      assert activity(board) == ["Key 17 added the task “Ours”."]
      refute render(board) =~ "Their"

      {:ok, item, _html} = live(conn, item_path(ours))
      assert has_element?(item, "h1", "Ours")
      assert has_element?(item, "p", "Nothing is linked to this yet.")
      assert history(item) == ["Key 17 added the task “Ours”."]
      refute render(item) =~ "Their"

      {:ok, missing, _html} = live(conn, "/app/fleets/#{@fleet}/workspace/goal%237")
      assert has_element?(missing, "h2", "This item isn’t in the workspace.")
    end
  end

  describe "an item with the same id in another fleet" do
    test "is named by this fleet's own item", %{conn: conn} do
      open_log(@fleet)
      open_log(@later)
      ours = create(@fleet, "task", %{"title" => "Ours", "progress" => "todo"}, id: "task#1")
      goal = create(@fleet, "goal", %{"title" => "Our goal", "outcome" => "o"}, id: "goal#2")
      link(@fleet, ours, goal, "implements")
      create(@later, "task", %{"title" => "Theirs", "progress" => "todo"}, id: "task#1")
      create(@later, "goal", %{"title" => "Their goal", "outcome" => "o"}, id: "goal#2")

      {:ok, board, _html} = live(conn, @board)

      assert activity(board) == [
               "Key 17 linked “Ours” to “Our goal”, which it delivers on.",
               "Key 17 added the goal “Our goal”.",
               "Key 17 added the task “Ours”."
             ]

      {:ok, item, _html} = live(conn, item_path(ours))
      assert has_element?(item, "#workspace-links", "Our goal")
      assert hd(history(item)) == "Key 17 linked “Ours” to “Our goal”, which it delivers on."
      refute render(item) =~ "Their"
    end
  end

  describe "text people wrote" do
    setup do
      open_log(@fleet)
      :ok
    end

    test "is shown as text, and only safe addresses become links", %{conn: conn} do
      evidence =
        create(@fleet, "evidence", %{
          "title" => ~s{<script>alert("title")</script>},
          "source_uri" => "javascript:alert(1)",
          "excerpt" => ~s{<img src=x onerror="alert(2)">},
          "how_obtained" => "data:text/html,<script>alert(3)</script>",
          "digest" => ~s{https://example.com/"onmouseover="alert(4)},
          "mirrors" => [
            "ipfs://bafyexample",
            "ar://example",
            "http://example.com/plain",
            "JavaScript:alert(5)",
            "https://example.com/has space",
            " https://example.com/leading"
          ]
        })

      create(@fleet, "task", %{
        "title" => "javascript:alert(6)",
        "progress" => "todo",
        "next_step" => "<b>bold</b>"
      })

      {:ok, board, _html} = live(conn, @board)
      {:ok, item, _html} = live(conn, item_path(evidence))

      for view <- [board, item] do
        page = workspace(view)

        assert page
               |> LazyHTML.query("script, img, b, [onerror], [onmouseover]")
               |> Enum.to_list() == []

        hrefs = page |> LazyHTML.query("a") |> LazyHTML.attribute("href")

        assert Enum.all?(
                 hrefs,
                 &String.starts_with?(&1, [
                   "/app/",
                   "https://",
                   "ipfs://",
                   "ar://",
                   "git+https://"
                 ])
               )

        for anchor <- LazyHTML.query(page, "a"),
            [href] = LazyHTML.attribute(anchor, "href"),
            not String.starts_with?(href, "/") do
          assert LazyHTML.attribute(anchor, "rel") == ["noopener noreferrer nofollow ugc"]
        end
      end

      board_text = board |> workspace() |> LazyHTML.text()
      assert board_text =~ ~s{<script>alert("title")</script>}
      assert board_text =~ "javascript:alert(1)"
      assert board_text =~ "javascript:alert(6)"
      assert board_text =~ "<b>bold</b>"

      page = workspace(item)

      assert page |> LazyHTML.query("h1") |> LazyHTML.text() ==
               ~s{<script>alert("title")</script>}

      links = page |> LazyHTML.query("#workspace-fields a") |> LazyHTML.attribute("href")

      assert links == [
               ~s{https://example.com/"onmouseover="alert(4)},
               "ipfs://bafyexample",
               "ar://example"
             ]

      text = LazyHTML.text(page)

      for shown <- [
            "javascript:alert(1)",
            ~s{<img src=x onerror="alert(2)">},
            "data:text/html,<script>alert(3)</script>",
            "http://example.com/plain",
            "JavaScript:alert(5)",
            "https://example.com/has space"
          ] do
        assert text =~ shown
      end
    end
  end

  describe "a workspace not ready to read" do
    test "says so", %{conn: conn} do
      {:ok, view, html} = live(conn, @board)

      assert html =~ @notice

      assert has_element?(
               view,
               "#workspace-unavailable h2",
               "This workspace isn’t ready to read yet."
             )

      refute has_element?(view, "#workspace-cards")

      {:ok, item, _html} = live(conn, "/app/fleets/#{@fleet}/workspace/task%231")

      assert has_element?(
               item,
               "#workspace-unavailable h2",
               "This workspace isn’t ready to read yet."
             )
    end

    test "of a fleet there is not says so, as the fleet's own page does", %{conn: conn} do
      for path <- [
            "/app/fleets/no_such_fleet/workspace",
            "/app/fleets/no_such_fleet/workspace/task%231"
          ] do
        {:ok, view, html} = live(conn, path)
        assert has_element?(view, "h1", "Keyfleet")
        assert has_element?(view, ".workspace-kicker", "Fleet")
        assert has_element?(view, "#workspace-unavailable h2", "This fleet doesn’t exist.")
        refute html =~ @notice
      end

      {:ok, fleet_page, _html} = live(conn, "/app/fleets/no_such_fleet")
      assert has_element?(fleet_page, "h1", "Keyfleet")
      assert has_element?(fleet_page, "h2", "This fleet doesn’t exist.")
    end
  end

  test "a visitor who holds none of the fleet's Keys is shown only that the workspace is for Key holders",
       %{visitor: visitor} do
    open_log(@fleet)
    task = create(@fleet, "task", %{"title" => "Draft the brief", "progress" => "todo"})

    for conn <- [visitor, signed_in_as(visitor, "0x" <> String.duplicate("e", 40))],
        path <- [@board, item_path(task)] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#workspace-members-only", "The workspace is for Key holders.")

      assert has_element?(
               view,
               ~s(#workspace-members-only a[href="/app/fleets/#{@fleet}#fleet-keys"])
             )

      refute html =~ "Draft the brief"
      refute html =~ @notice
    end
  end

  test "the fleet's page leads to its workspace", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")

    assert has_element?(view, ~s(#fleet-workspace-link[href="#{@board}"]), "Workspace")
  end

  defp item_path(id), do: KeyfleetWeb.WorkspacePage.item_path(@fleet, id)

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:workspace-page:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

  defp id_number(id), do: id |> String.split("#") |> List.last()

  defp card(id), do: ~s(#workspace-cards [data-item="#{id}"])

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-cards > li")
    |> LazyHTML.attribute("data-item")
  end

  defp card_text(view, id),
    do:
      view
      |> element(card(id))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> squish()

  defp facts(view, id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(card(id) <> " .workspace-facts div")
    |> Enum.map(fn fact ->
      {fact |> LazyHTML.query("dt") |> LazyHTML.text(),
       fact |> LazyHTML.query("dd") |> LazyHTML.text()}
    end)
  end

  defp workspace(view),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".workspace-page")

  defp linked(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-links > li a")
    |> LazyHTML.attribute("data-item-link")
  end

  defp history(view), do: lines(view, "#workspace-history > li > p:first-child")
  defp activity(view), do: lines(view, "#workspace-activity > li > p:first-child")

  defp lines(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # A page position as the site writes one: the sort values it follows.
  defp keyset(values), do: values |> :erlang.term_to_binary() |> Base.encode64()

  # Tells this test each time the open page reads the workspace again.
  defp watch_reads(view) do
    id = "workspace-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:keyfleet, :repo, :query],
      &__MODULE__.report_read/4,
      {self(), view.pid}
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def report_read(_event, _measurements, %{source: "graph_cursors"}, {test, page}) do
    if self() == page, do: send(test, :workspace_read)
  end

  def report_read(_event, _measurements, _meta, _config), do: :ok
end
