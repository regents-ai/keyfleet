defmodule KeyfleetWeb.Live.WorkspacePageTest do
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Keyfleet.WorkspaceFixtures

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CodeHistory
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  # `general`'s repository is named after its fleet.
  @repository @fleet
  @other "fibonacci_cascade"
  # A fleet whose name sorts after this one's.
  @later "fleet_tech_classic"
  @too_far 9_223_372_036_854_775_808
  @board "/syndicate/1/workspace"
  @notice "Every Key holder can read this. Never put passwords or private data here."
  @holder "0x" <> String.duplicate("d", 40)
  @member "0x" <> String.duplicate("c", 40)

  # The fleet is recorded as deployed, because a fleet still coming soon
  # has no workspace to show. Each page is read by the owner of one of its
  # Keys, as only a Key holder reads the workspace.
  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    hold!(1, @holder)

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

      assert has_element?(view, "#fleet-view h1", "Syndicate #1")
      assert has_element?(view, ~s(#fleet-tab-workspace[aria-current="page"]))

      assert cards(view) == [dead_end, note, service, evidence, finding, task, goal]

      assert card_text(view, goal) =~ "Goal"
      assert {"Status", "Open"} in facts(view, goal)
      assert card_text(view, goal) =~ "One paying customer."
      assert {"Progress", "In progress"} in facts(view, task)
      assert {"Taken by", "Key 42"} in facts(view, task)

      assert has_element?(
               view,
               ~s(#{card(task)} a[href="#{Keyfleet.Fleets.path(@fleet)}?key=42"]),
               "Key 42"
             )

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
      assert has_element?(
               view,
               ~s(#{card(service)} a[href="#{Keyfleet.Fleets.path(@fleet)}?key=5"]),
               "Key 5"
             )

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
      submit(@fleet, first, "https://example.com/first", by: 9)

      {:ok, view, _html} = live(conn, @board)

      assert cards(view) == [first, second]

      assert facts(view, first) == [
               {"Progress", "Submitted"},
               {"Review", "Awaiting review"},
               {"Taken by", "Key 9"}
             ]

      assert card_text(view, first) =~ "Last changed 22 September 2026 at 12:05 UTC"
      assert card_text(view, first) =~ "Added by Key 17"
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
      archived = create(@fleet, "task", %{"title" => "Old task", "progress" => "todo"})
      submit(@fleet, archived, "https://example.com/old")
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
            "#{Keyfleet.Fleets.path(@fleet)}/workspace/task%231%232",
            "#{Keyfleet.Fleets.path(@fleet)}/workspace/rel_1"
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

    test "the places to work come first", %{conn: conn} do
      {:ok, _board, html} = live(conn, @board)

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#workspace-page > *")
        |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> List.first()))

      assert List.first(ids) == "workspace-places"
    end

    test "the goals lead the work, the newest change first, and Keyfleet added the starting ones",
         %{conn: conn} do
      second = starting_goal(@fleet, 2, %{"title" => "Compete", "outcome" => "Pick a board."})
      first = starting_goal(@fleet, 1, %{"title" => "Plan a service", "outcome" => "Find one."})
      goal = create(@fleet, "goal", %{"title" => "Ship", "outcome" => "It ships."})
      create(@fleet, "note", %{"title" => "Standup", "body" => "b"})

      {:ok, board, html} = live(conn, @board)
      assert html =~ @notice
      assert goals(board) == [goal, first, second]
      assert has_element?(board, ~s(#workspace-goals [data-item="#{first}"]), "Starting idea")
      refute has_element?(board, ~s(#workspace-goals [data-item="#{first}"]), "Open")
      refute has_element?(board, ~s(#workspace-goals [data-item="#{goal}"]), "Starting idea")
      refute has_element?(board, ~s(#workspace-goals [data-item="#{second}"]), "joined")
      assert has_element?(board, ~s(#workspace-all-goals[href="#{@board}?type=goal"]))
      assert "Keyfleet added the goal “Plan a service”." in activity(board)

      join(@fleet, second, by: 18)
      {:ok, board, _html} = live(conn, @board)
      assert goals(board) == [second, goal, first]
      assert has_element?(board, ~s(#workspace-goals [data-item="#{second}"]), "1 joined")

      # Every goal is one line, there as on the list of every goal.
      board |> element("#workspace-all-goals") |> render_click()
      assert cards(board) == [second, goal, first]

      assert has_element?(
               board,
               ~s(#workspace-cards .workspace-row[data-item="#{first}"]),
               "Starting idea"
             )

      {:ok, item, html} = live(conn, item_path(first))
      assert html =~ "Starting idea"
      assert has_element?(item, ".workspace-detail", "Added by Keyfleet")
    end

    test "an item that isn't in the workspace says so", %{conn: conn} do
      {:ok, view, html} = live(conn, "#{Keyfleet.Fleets.path(@fleet)}/workspace/task%23999")

      assert html =~ @notice
      assert has_element?(view, "h2", "This item isn’t in the workspace.")
    end

    test "the only presses are pins, the Key's projects, and opening the notebooks or the code",
         %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "A task", "progress" => "todo"})
      {:ok, board, _html} = live(conn, @board)
      {:ok, item, _html} = live(conn, item_path(task))
      {:ok, docs, _html} = live(conn, @board <> "?place=docs")
      {:ok, code, _html} = live(conn, @board <> "?place=code")

      assert workspace(board) |> LazyHTML.to_html() =~ "A task"
      assert workspace(item) |> LazyHTML.to_html() =~ "A task"

      # Key 1 holds no active project, so it may start one.
      for {view, forms, presses} <- [
            {board, ["project_start"], []},
            {item, [], []},
            {docs, ["project_start"], []},
            {code, ["project_start"], ["get_code_password"]}
          ] do
        page = workspace(view)
        assert page |> LazyHTML.query("[phx-submit]") |> LazyHTML.attribute("phx-submit") == forms
        assert page |> LazyHTML.query("[phx-click]") |> LazyHTML.attribute("phx-click") == presses
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
      assert has_element?(view, ".workspace-heading h2", "Draft the brief")

      assert has_element?(
               view,
               ~s(#workspace-item-page .workspace-kicker a[href="#{@board}"]),
               "Workspace"
             )

      fields =
        view
        |> workspace()
        |> LazyHTML.query("#workspace-fields dt")
        |> Enum.map(&LazyHTML.text/1)

      assert fields == ["Progress", "Taken by", "Deliverable", "Result", "Extra notes"]
      assert has_element?(view, "#workspace-fields", "In progress")

      assert has_element?(
               view,
               ~s(#workspace-fields a[href="#{Keyfleet.Fleets.path(@fleet)}?key=42"]),
               "Key 42"
             )

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
               ~s(#workspace-discussion a[href="#{Keyfleet.Fleets.path(@fleet)}?room=business"]),
               "Message 4 in Business"
             )

      # An open room goes by the name its members gave it.
      assert has_element?(
               view,
               ~s(#workspace-discussion a[href="#{Keyfleet.Fleets.path(@fleet)}?room=open-2"]),
               "Message 1 in Hull survey"
             )

      # So does a room an agent created.
      assert has_element?(
               view,
               ~s(#workspace-discussion a[href="#{Keyfleet.Fleets.path(@fleet)}?room=ship-ops"]),
               "Message 3 in Ship ops"
             )

      assert has_element?(view, "#workspace-discussion span", "Message 2 in elsewhere")
      refute has_element?(view, ~s(#workspace-discussion a[href*="elsewhere"]))

      {:ok, goal_view, _html} = live(conn, item_path(goal))

      refute has_element?(goal_view, "#workspace-links")
      assert work(goal_view) == [task]

      assert has_element?(
               goal_view,
               ~s(#workspace-goal-map-items [data-item="#{task}"] a[href="#{item_path(task)}"]),
               "Draft the brief"
             )

      assert has_element?(
               goal_view,
               ~s(#workspace-goal-map-items [data-item="#{task}"]),
               "In progress"
             )

      assert has_element?(goal_view, "p", "No one has mentioned this in the rooms yet.")
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

      assert has_element?(view, ".workspace-heading h2", "Scraping the forum")

      fields =
        view
        |> workspace()
        |> LazyHTML.query("#workspace-fields div")
        |> Enum.map(fn field ->
          {field |> LazyHTML.query("dt") |> LazyHTML.text(),
           field |> LazyHTML.query("dd") |> LazyHTML.text() |> squish()}
        end)

      assert fields == [
               {"Approach tried", "Paged through the archive."},
               {"Reason", "It needs a login."}
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

      assert has_element?(view, "p", "No work is linked to this goal yet.")

      assert history(view) == [
               "Key 8 unlinked “Draft” from “Revenue”, which it no longer delivers on.",
               "Key 17 linked “Draft” to “Revenue”, which it delivers on.",
               "Key 17 added the goal “Revenue”."
             ]
    end

    test "a fork reads as the task being forked, and the copy names the task it copies", %{
      conn: conn
    } do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "doing"})
      fork = create(@fleet, "task", %{"title" => "Draft", "progress" => "doing"}, by: 9)
      link(@fleet, fork, task, "forks", by: 9)

      {:ok, view, _html} = live(conn, item_path(fork))

      assert has_element?(
               view,
               ~s(#workspace-links [data-direction="from"]),
               "This task copies"
             )

      assert history(view) == ["Key 9 forked “Draft”.", "Key 9 added the task “Draft”."]
    end

    test "a goal's page lists the work around it, its notebook results and its commits",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      task = create(@fleet, "task", %{"title" => "Price check", "progress" => "doing"})
      link(@fleet, task, goal, "implements")
      finding = create(@fleet, "finding", %{"title" => "Funds pay", "statement" => "s"})
      link(@fleet, finding, goal, "supports")

      hash = String.duplicate("ab", 20)
      commit = KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, hash)

      result =
        Keyfleet.Notebooks.result_url(
          @fleet,
          "nb-0123456789abcdef",
          "run_01M539TC83WX2ZRQFZB4VHH178",
          1_792_186_134_702
        )

      code = create(@fleet, "evidence", %{"title" => "The price page", "source_uri" => commit})
      run = create(@fleet, "evidence", %{"title" => "The forecast", "source_uri" => result})
      link(@fleet, task, code, "produces")
      link(@fleet, task, run, "produces")

      # What the goal's work links to further on, and what is put away, stays off it.
      far = create(@fleet, "note", %{"title" => "Aside", "body" => "b"})
      link(@fleet, far, finding, "references")
      old = create(@fleet, "task", %{"title" => "Old try", "progress" => "todo"})
      link(@fleet, old, goal, "implements")
      archive(@fleet, old)

      {:ok, view, _html} = live(conn, item_path(goal))

      assert work(view) == [task, code, run, finding]
      assert has_element?(view, ~s(#workspace-goal-map-items [data-item="#{task}"]), "Task")
      refute has_element?(view, "#workspace-goal-map-more")

      assert has_element?(
               view,
               ~s(#workspace-goal-notebook-rows [data-item="#{run}"] a[data-notebook-result][href="#{result}"]),
               "The forecast"
             )

      assert has_element?(
               view,
               ~s(#workspace-goal-code-rows [data-item="#{code}"] a[href="#{Keyfleet.Code.commit_path(@fleet, @repository, hash)}"]),
               "The price page"
             )

      assert has_element?(view, "#workspace-goal-code-rows code", String.slice(hash, 0, 12))
    end

    test "a goal's page with nothing around it says so", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(
               view,
               "#workspace-goal-map-empty",
               "No work is linked to this goal yet."
             )

      assert has_element?(view, "#workspace-goal-code-empty", "Nothing here yet.")

      assert has_element?(
               view,
               "#workspace-goal-notebooks-none",
               "Notebooks aren’t connected for this fleet yet."
             )

      refute has_element?(view, "#workspace-goal-notebooks-empty")

      # Where its code goes is named, and links nowhere until something is there.
      assert has_element?(view, "#workspace-goal-folder-name", "goals/goal-#{id_number(goal)}")
      refute has_element?(view, "#workspace-goal-folder")
    end

    test "a goal's map holds the goal and the 119 most recently changed items around it",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Hub", "outcome" => "o", "status" => "open"})

      notes =
        for n <- 1..120 do
          note = create(@fleet, "note", %{"title" => "Note #{n}", "body" => "b"})
          link(@fleet, note, goal, "references")
          note
        end

      {:ok, view, _html} = live(conn, item_path(goal))

      # The goal changed longest ago, yet it stays in its own map, so the
      # oldest note is the one left out and the notes hang from the goal.
      assert Enum.sort(work(view)) == notes |> Enum.drop(1) |> Enum.sort()
      assert has_element?(view, "#workspace-goal-map-more", "The 120 most recently changed.")

      {:ok, graph, _html} =
        live(conn, @board <> "?view=graph&goal=" <> URI.encode_www_form(goal))

      assert has_element?(graph, "#workspace-graph-goal", "Hub")
    end

    test "a review is told once, as its decision on the task", %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "doing"})
      submit(@fleet, task, "https://example.com/draft", by: 9)
      review = review(@fleet, task, "dispute", by: 4)

      {:ok, board, _html} = live(conn, @board)

      assert Enum.take(activity(board), 2) == [
               "Key 4 disputed “Draft”.",
               "Key 9 submitted “Draft” for review."
             ]

      {:ok, item, _html} = live(conn, item_path(task))
      assert has_element?(item, "#workspace-fields", "Disputed")

      assert history(item) == [
               "Key 4 disputed “Draft”.",
               "Key 9 submitted “Draft” for review.",
               "Key 17 added the task “Draft”."
             ]

      {:ok, item, _html} = live(conn, item_path(review))
      assert history(item) == ["Key 4 disputed “Draft”."]
    end

    test "a task's page shows its reviewer, what must hold, its notebook and commit, and whether each review reproduced it",
         %{conn: conn} do
      hash = String.duplicate("cd", 20)
      notebook = "/projects/proj-0123456789abcdef/notebooks/nb-0123456789abcdef"

      task =
        create(@fleet, "task", %{
          "title" => "Fewer notices",
          "progress" => "doing",
          "reviewer_key" => 4,
          "acceptance_criteria" => ["At most one notice a minute"],
          "commit_ref" => KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, hash),
          "notebook_ref" => Keyfleet.Notebooks.url(@fleet, notebook)
        })

      submit(@fleet, task, "https://example.com/result", by: 9)
      review = review(@fleet, task, "accept", by: 4, reproduction: "passed")
      commit_path = Keyfleet.Code.commit_path(@fleet, @repository, hash)
      open = "/fleets/#{@fleet}/notebooks/open?" <> URI.encode_query(to: notebook)

      {:ok, item, _html} = live(conn, item_path(task))
      assert has_element?(item, "#workspace-fields", "Key 4")
      assert has_element?(item, "#workspace-fields", "At most one notice a minute")

      assert has_element?(
               item,
               ~s(#workspace-fields a[data-commit="#{hash}"][href="#{commit_path}"])
             )

      assert has_element?(item, ~s(#workspace-fields a[data-notebook][href="#{open}"]))
      assert has_element?(item, "#workspace-links", "Review: accepted, reproduced")

      {:ok, item, _html} = live(conn, item_path(review))
      assert has_element?(item, "#workspace-fields", "Yes")
      assert has_element?(item, ~s(#workspace-fields a[href="#{commit_path}"]))

      {:ok, commit, _html} = live(conn, commit_path)

      assert has_element?(
               commit,
               ~s(#workspace-commit-citing [data-item="#{task}"]),
               "Fewer notices"
             )
    end

    test "links and history come fifty at a time", %{conn: conn} do
      hub = create(@fleet, "task", %{"title" => "Hub", "progress" => "todo"})

      tasks =
        for n <- 1..52 do
          task = create(@fleet, "task", %{"title" => "Task #{n}", "progress" => "todo"})
          link(@fleet, task, hub, "depends_on")
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
               "Key 17 linked “Task 2” to “Hub”, which it depends on.",
               "Key 17 linked “Task 1” to “Hub”, which it depends on.",
               "Key 17 added the task “Hub”."
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

  describe "a goal's own place in the code and the notebooks" do
    setup do
      open_log(@fleet)
      :ok
    end

    test "a goal's page lists the files in its folder, and each opens to the file", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      folder = "goals/goal-#{id_number(goal)}"

      store!(%{
        (folder <> "/plan.md") => "# Plan\nSell one Key.\n",
        (folder <> "/model/price.py") => "PRICE = 10\n",
        "README.md" => "Top"
      })

      {:ok, view, _html} = live(conn, item_path(goal))

      assert rows(view, "#workspace-goal-code-rows") == [
               ["Folder", "model"],
               ["File", "plan.md", "21 B"]
             ]

      assert has_element?(
               view,
               ~s(#workspace-goal-folder[href="#{Keyfleet.Code.files_path(@fleet, @repository, folder)}"]),
               folder
             )

      assert has_element?(
               view,
               ~s(#workspace-goal-code-rows [data-file="plan.md"] a[href="#{Keyfleet.Code.files_path(@fleet, @repository, folder <> "/plan.md")}"])
             )

      file = view
      file |> element(~s(#workspace-goal-code-rows [data-file="plan.md"] a)) |> render_click()
      assert_patch(file, Keyfleet.Code.files_path(@fleet, @repository, folder <> "/plan.md"))

      assert text(file, "#workspace-file") == "# Plan\nSell one Key.\n"

      assert lines(file, "#workspace-files-crumbs > a") == [
               "Code",
               "goals",
               "goal-#{id_number(goal)}"
             ]

      assert has_element?(file, "#workspace-files-page h2", "plan.md")

      # Every read of the code carries a pass for this fleet's code alone.
      assert_received {:store, _path, ["Bearer " <> pass]}
      assert {:ok, %{"fleet" => @fleet, "scope" => "read"}} = claims(pass)
    end

    test "a goal's page says so when the code can't be read", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      Keyfleet.Code.record_repository!(@repository, "z6MkOwner", actor: %Actors.System{})
      Req.Test.stub(Keyfleet.Code.NodeClient, &Plug.Conn.send_resp(&1, 503, ""))

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(
               view,
               "#workspace-goal-code-unreadable",
               "The code can’t be read right now. Try again in a minute."
             )

      refute has_element?(view, "#workspace-goal-code-empty")
    end

    test "a goal's page lists the notebooks tagged with its name, each opening that notebook",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      tag = "goal-#{id_number(goal)}"
      project = "proj-0123456789abcdef"
      notebook = "nb-0123456789abcdef"

      hub!(project, fn %{"tag" => ^tag, "limit" => "50"} ->
        [
          %{
            "id" => notebook,
            "title" => "Price model",
            "description" => "",
            "created_at" => "2026-10-20T09:00:00Z",
            "tags" => []
          }
        ]
      end)

      {:ok, view, _html} = live(conn, item_path(goal))

      to = Keyfleet.Notebooks.notebook_path(project, notebook)
      assert Keyfleet.Notebooks.destination?(to)
      open = "/fleets/#{@fleet}/notebooks/open?" <> URI.encode_query(to: to)

      assert has_element?(
               view,
               ~s(#workspace-goal-notebook-rows [data-notebook="#{notebook}"] a[href="#{open}"]),
               "Price model"
             )

      refute has_element?(view, "#workspace-goal-notebooks-none")
    end

    # A task is cited by its own fields: the goal's page found only what
    # evidence cited, so a task's notebook and commit never showed there.
    test "a goal's page lists the notebook, result and commit its tasks cite",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      project = "proj-0123456789abcdef"
      notebook = "nb-0123456789abcdef"
      hash = String.duplicate("cd", 20)

      result =
        Keyfleet.Notebooks.result_url(
          @fleet,
          notebook,
          "run_01M539TC83WX2ZRQFZB4VHH178",
          1_792_186_134_702
        )

      task =
        create(@fleet, "task", %{
          "title" => "Price check",
          "progress" => "doing",
          "commit_ref" => KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, hash),
          "notebook_ref" => Keyfleet.Notebooks.notebook_url(@fleet, project, notebook),
          "result_ref" => result
        })

      link(@fleet, task, goal, "implements")

      hub!(project, fn
        %{"tag" => _tag} ->
          []

        {:notebook, ^notebook} ->
          %{
            "id" => notebook,
            "title" => "Price model",
            "description" => "",
            "status" => "active",
            "created_at" => "2026-10-20T09:00:00Z",
            "tags" => []
          }
      end)

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(
               view,
               ~s(#workspace-goal-notebook-rows [data-notebook="#{notebook}"]),
               "Price model"
             )

      assert has_element?(
               view,
               ~s(#workspace-goal-notebook-rows [data-item="#{task}"] a[href="#{result}"]),
               "Price check"
             )

      assert has_element?(
               view,
               ~s(#workspace-goal-code-rows [data-item="#{task}"] a[href="#{Keyfleet.Code.commit_path(@fleet, @repository, hash)}"]),
               "Price check"
             )
    end

    # Cited notebooks were looked for among the fleet's newest 50 only, so an
    # older one vanished from the goal's page; then each was asked for with no
    # cap or deadline, and one failed answer blanked the list.
    test "a goal's page asks for each cited notebook by its id, keeping what the hub answers in time",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      project = "proj-0123456789abcdef"

      [old, deleted, gone, down, slow] =
        ~w(nb-00000000000000a1 nb-00000000000000d2 nb-00000000000000e3 nb-00000000000000f4 nb-00000000000000b5)

      cite!(goal, project, [old, deleted, gone, down, slow])
      meta = &meta(&1, &2, "active")

      hub!(project, fn
        %{"tag" => _tag} -> []
        {:notebook, ^old} -> meta.(old, "Old model")
        {:notebook, ^deleted} -> meta(deleted, "Deleted", "deleted")
        {:notebook, ^gone} -> nil
        {:notebook, ^down} -> :down
        {:notebook, ^slow} -> {:slow, meta.(slow, "Slow")}
      end)

      notebooks = Application.fetch_env!(:keyfleet, :notebooks)
      Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :page_timeout_ms, 200))

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(
               view,
               ~s(#workspace-goal-notebook-rows [data-notebook="#{old}"]),
               "Old model"
             )

      for id <- [deleted, gone, down, slow] do
        refute has_element?(view, ~s(#workspace-goal-notebook-rows [data-notebook="#{id}"]))
      end

      assert has_element?(view, "#workspace-goal-notebooks-unshown", "2 more not shown.")
      refute has_element?(view, "#workspace-goal-notebooks-unreadable")
    end

    test "a goal's page asks the hub for the 20 most recently cited notebooks only",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      project = "proj-0123456789abcdef"
      ids = for n <- 1..21, do: "nb-" <> String.pad_leading(Integer.to_string(n), 16, "0")
      cite!(goal, project, ids)
      test = self()

      hub!(project, fn
        %{"tag" => _tag} ->
          []

        {:notebook, id} ->
          send(test, {:asked, id})
          meta(id, "Notebook " <> id, "active")
      end)

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(view, "#workspace-goal-notebooks-unshown", "1 more not shown.")
      assert collect_asked() |> Enum.uniq() |> length() == 20
    end

    test "a goal's page says so when the notebooks can't be read", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue", "outcome" => "o", "status" => "open"})
      hub!("proj-0123456789abcdef", :down)

      {:ok, view, _html} = live(conn, item_path(goal))

      assert has_element?(
               view,
               "#workspace-goal-notebooks-unreadable",
               "The notebooks can’t be read right now. Try again in a minute."
             )

      refute has_element?(view, "#workspace-goal-notebooks-empty")
    end
  end

  describe "the fleet's code" do
    setup do
      open_log(@fleet)

      store!(%{
        "README.md" => "Hello",
        "goals/goal-1/data.bin" => <<0, 1, 2>>,
        "goals/goal-1/big.txt" => String.duplicate("a", 512 * 1024 + 1),
        "goals/goal-1/notes/one.md" => "one"
      })

      :ok
    end

    test "opens at the top folder, folders first, with how to copy it and what was sent lately",
         %{conn: conn} do
      Keyfleet.Code.record_pushes(@fleet, "general", %{token_id: 1, wallet: @holder}, [
        %{ref: "refs/heads/main", head: String.duplicate("5", 40)}
      ])

      {:ok, view, _html} = live(conn, Keyfleet.Code.files_path(@fleet, @repository, ""))

      assert rows(view, "#workspace-file-rows") == [
               ["Folder", "goals"],
               ["File", "README.md", "5 B"]
             ]

      assert has_element?(view, "#workspace-files-page h2", "Code")
      refute has_element?(view, "#workspace-files-crumbs")
      assert has_element?(view, "#workspace-files-clone", Keyfleet.Code.clone_url(@repository))
      assert has_element?(view, "#workspace-files-pushes", "Key 1 sent changes to main")

      view |> element(~s(#workspace-file-rows [data-file="goals"] a)) |> render_click()
      assert_patch(view, Keyfleet.Code.files_path(@fleet, @repository, "goals"))
      assert rows(view, "#workspace-file-rows") == [["Folder", "goal-1"]]
    end

    test "names a file that isn't text, or is too large, without showing it", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, Keyfleet.Code.files_path(@fleet, @repository, "goals/goal-1/data.bin"))

      assert has_element?(view, "#workspace-file-not-text")
      refute has_element?(view, "#workspace-file")

      {:ok, view, _html} =
        live(conn, Keyfleet.Code.files_path(@fleet, @repository, "goals/goal-1/big.txt"))

      assert has_element?(view, "#workspace-file-too-large")
      refute has_element?(view, "#workspace-file")
    end

    test "a place that isn't in the code, or can't be one, is a page that doesn't exist",
         %{conn: conn} do
      for path <- ["goals/goal-2", "goals//goal-1", "goals/../README.md", "/README.md", ""] do
        assert_raise KeyfleetWeb.NotFoundError, fn ->
          live(
            conn,
            Keyfleet.Code.files_path(@fleet, @repository, "") <>
              "?" <> URI.encode_query(path: path)
          )
        end
      end

      assert_raise KeyfleetWeb.NotFoundError, fn ->
        live(conn, Keyfleet.Fleets.path(@fleet) <> "/code/#{@other}/files")
      end
    end

    test "a file a later change removed says so, and leads back to the top of the code",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, Keyfleet.Code.files_path(@fleet, @repository, "README.md"))
      assert has_element?(view, "#workspace-file")

      serve_code(%{"goals/goal-1/notes/one.md" => "one"})
      send(view.pid, :refresh_workspace)

      assert has_element?(view, "#workspace-files-removed", "A later change removed this")
      refute has_element?(view, "#workspace-file")

      view |> element("#workspace-files-removed a") |> render_click()
      assert_patch(view, Keyfleet.Code.files_path(@fleet, @repository, ""))
      assert rows(view, "#workspace-file-rows") == [["Folder", "goals"]]
    end

    test "says so when the code can't be read", %{conn: conn} do
      Req.Test.stub(Keyfleet.Code.NodeClient, &Plug.Conn.send_resp(&1, 503, ""))
      {:ok, view, _html} = live(conn, Keyfleet.Code.files_path(@fleet, @repository, "README.md"))

      assert has_element?(
               view,
               "#workspace-files-unreadable",
               "The code can’t be read right now. Try again in a minute."
             )
    end

    test "shows only that it is members' code to anyone else, and offers Sign in to a visitor",
         %{visitor: visitor} do
      path = Keyfleet.Code.files_path(@fleet, @repository, "README.md")

      {:ok, signed_out, _html} = live(visitor, path)
      assert has_element?(signed_out, "#workspace-files-members-only")
      assert has_element?(signed_out, "#workspace-files-sign-in")
      refute has_element?(signed_out, "#workspace-files")

      outsider = signed_in_as(visitor, "0x" <> String.duplicate("e", 40))
      {:ok, signed_in, _html} = live(outsider, path)
      assert has_element?(signed_in, "#workspace-files-members-only")
      refute has_element?(signed_in, "#workspace-files-sign-in")
      refute_received {:store, _path, _pass}
    end
  end

  describe "the workspace's three places" do
    setup do
      open_log(@fleet)
      take_over_general()
      :ok
    end

    test "the switch leads to each place, and a place the workspace doesn't have is a page that doesn't exist",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @board)

      assert has_element?(
               view,
               ~s(#workspace-tab-project[aria-selected="true"][href="#{@board}"])
             )

      assert has_element?(view, ~s(#workspace-tab-docs[href="#{@board}?place=docs"]))
      assert has_element?(view, ~s(#workspace-tab-code[href="#{@board}?place=code"]))
      assert has_element?(view, "#workspace-goals")

      view |> element("#workspace-tab-docs") |> render_click()
      assert_patch(view, @board <> "?place=docs")
      assert has_element?(view, ~s(#workspace-tab-docs[aria-selected="true"]))
      assert has_element?(view, "#workspace-notebooks")
      refute has_element?(view, "#workspace-goals")

      view |> element("#workspace-tab-code") |> render_click()
      assert_patch(view, @board <> "?place=code")
      assert has_element?(view, "#workspace-code")

      assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, @board <> "?place=chat") end
    end

    test "Docs lists the newest notebooks, and a pin keeps one at hand for every member",
         %{conn: conn, visitor: visitor} do
      project = "proj-0123456789abcdef"
      price = "nb-0123456789abcdef"
      plan = "nb-fedcba9876543210"
      test = self()

      hub!(project, fn query ->
        send(test, {:listed, query})

        [
          %{
            "id" => plan,
            "title" => "Launch plan",
            "description" => "Who buys first.",
            "created_at" => "2026-10-20T09:00:00Z",
            "tags" => ["goal-1", "folder/plans/launch"]
          },
          %{
            "id" => price,
            "title" => "Price model",
            "description" => "",
            "created_at" => "2026-10-19T09:00:00Z",
            "tags" => []
          }
        ]
      end)

      {:ok, view, _html} = live(conn, @board <> "?place=docs&project=general")
      assert_received {:listed, %{"limit" => "24"} = query}
      refute Map.has_key?(query, "tag")

      # Notebooks in no folder come first, then each folder under its name.
      assert rows(view, "#workspace-notebook-rows section:not([data-folder]) ol") == [
               ["Price model", "Locked 19 Oct 2026"]
             ]

      assert text(view, ~s(#workspace-notebook-rows [data-folder="plans/launch"] h3)) ==
               "plans/launch"

      assert rows(view, ~s(#workspace-notebook-rows [data-folder="plans/launch"] ol)) == [
               ["Launch plan", "Locked 20 Oct 2026"]
             ]

      assert has_element?(
               view,
               ~s([data-notebook="#{plan}"] .workspace-row-text),
               "Who buys first."
             )

      assert has_element?(view, "#workspace-docs-pins-empty")
      assert has_element?(view, "#open-notebooks")

      view
      |> element(~s(#workspace-notebook-#{price}-pin[aria-pressed="false"]))
      |> render_click()

      open =
        "/fleets/#{@fleet}/notebooks/open?" <>
          URI.encode_query(to: Keyfleet.Notebooks.notebook_path(project, price))

      assert has_element?(
               view,
               ~s(#workspace-docs-pins-rows [data-pin="#{price}"] a[href="#{open}"]),
               "Price model"
             )

      assert has_element?(view, ~s(#workspace-notebook-#{price}-pin[aria-pressed="true"]))

      # Another holder of one of the fleet's Keys sees the same pin, but only
      # its pinner lifts it.
      other = "0x" <> String.duplicate("b", 40)
      hold!(2, other)

      {:ok, theirs, _html} =
        live(signed_in_as(visitor, other), @board <> "?place=docs&project=general")

      assert has_element?(
               theirs,
               ~s(#workspace-docs-pins-rows [data-pin="#{price}"]),
               "Price model"
             )

      assert has_element?(
               theirs,
               ~s(#workspace-docs-pins-rows [data-pin="#{price}"] button[disabled])
             )

      view
      |> element(~s(#workspace-docs-pins-rows [data-pin="#{price}"] button))
      |> render_click()

      assert has_element?(view, "#workspace-docs-pins-empty")
      assert has_element?(view, ~s(#workspace-notebook-#{price}-pin[aria-pressed="false"]))
    end

    test "Docs says so when the notebooks aren't connected, or can't be read", %{conn: conn} do
      {:ok, view, _html} = live(conn, @board <> "?place=docs&project=general")
      assert has_element?(view, "#workspace-notebooks-none")
      refute has_element?(view, "#workspace-docs-pins")
      refute has_element?(view, "#workspace-docs-info")

      hub!("proj-0123456789abcdef", :down)
      {:ok, view, _html} = live(conn, @board <> "?place=docs&project=general")

      assert has_element?(
               view,
               "#workspace-notebooks-unreadable",
               "The notebooks can’t be read right now. Try again in a minute."
             )
    end

    test "Code lists the top folder with how to copy it, and a pinned file stays at hand",
         %{conn: conn} do
      store!(%{"README.md" => "Hello", "goals/goal-1/plan.md" => "Plan"})

      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")

      assert rows(view, "#workspace-code-rows") == [
               ["Folder", "goals"],
               ["File", "README.md", "5 B"]
             ]

      assert text(view, "#workspace-code-address") == Keyfleet.Code.clone_url(@repository)
      assert has_element?(view, ~s(#workspace-code-address-copy))
      assert has_element?(view, "#code-pushes-empty")
      assert has_element?(view, "#workspace-code-files")

      view |> element(~s(#workspace-code-rows [data-file="goals"] button)) |> render_click()
      view |> element(~s(#workspace-code-rows [data-file="README.md"] button)) |> render_click()

      # Newest pin first, each opening what it names.
      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#workspace-code-pins-rows > li")
             |> LazyHTML.attribute("data-pin") == ["README.md", "goals"]

      assert has_element?(
               view,
               ~s(#workspace-code-pins-rows [data-pin="README.md"] a[href="#{Keyfleet.Code.files_path(@fleet, @repository, "README.md")}"])
             )

      # The code's own pages show the same pin, and lift it.
      {:ok, files, _html} = live(conn, Keyfleet.Code.files_path(@fleet, @repository, ""))
      pin = ~s(#workspace-file-rows [data-file="README.md"] button)
      assert has_element?(files, pin <> ~s([aria-pressed="true"]))
      files |> element(pin) |> render_click()
      assert has_element?(files, pin <> ~s([aria-pressed="false"]))

      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")
      refute has_element?(view, ~s(#workspace-code-pins-rows [data-pin="README.md"]))
      assert has_element?(view, ~s(#workspace-code-pins-rows [data-pin="goals"]))
    end

    test "Code offers nothing to browse before files reach main, even after changes were sent",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")
      assert has_element?(view, "#workspace-code-empty")
      refute has_element?(view, "#workspace-code-files")

      Keyfleet.Code.record_pushes(@fleet, "general", %{token_id: 1, wallet: @holder}, [
        %{ref: "refs/heads/draft", head: String.duplicate("6", 40)}
      ])

      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")
      assert has_element?(view, "#code-pushes")
      assert has_element?(view, "#workspace-code-main-empty")
      refute has_element?(view, "#workspace-code-empty")
      refute has_element?(view, "#workspace-code-files")
    end

    test "Code gives a holder a git password, and says until when in the reader's own time",
         %{conn: conn} do
      store!(%{"README.md" => "Hello"})
      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")
      refute has_element?(view, "#code-password")

      view |> element("#get-code-password") |> render_click()

      assert {:ok, _subject, %Actors.Human{}} =
               view |> text("#code-password-text") |> KeyfleetWeb.CodePassword.read(@fleet)

      ttl = Keyfleet.Code.config()[:password_ttl_seconds]

      {:ok, until, 0} =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#code-password-until[phx-hook="LocalTime"][data-as="stamp"]))
        |> LazyHTML.attribute("datetime")
        |> List.first()
        |> DateTime.from_iso8601()

      assert_in_delta DateTime.diff(until, DateTime.utc_now()), ttl, 5
    end

    test "a pin is one per notebook or file, and only the fleet's members set or lift one" do
      holder = %Actors.Human{human_account_id: 1, wallet_addresses: [@holder]}

      pin = %{
        fleet_id: @fleet,
        project: "general",
        place: :code,
        target: "README.md",
        title: "README.md"
      }

      assert {:ok, first} = Graph.pin(pin, actor: holder)
      assert {:ok, again} = Graph.pin(%{pin | title: "Read me"}, actor: holder)
      assert again.id == first.id
      assert [%{title: "Read me"}] = Graph.pins!(@fleet, :code, "general", actor: holder)

      outsider = %Actors.Human{
        human_account_id: 0,
        wallet_addresses: ["0x" <> String.duplicate("e", 40)]
      }

      assert {:error, %Ash.Error.Forbidden{}} = Graph.pin(pin, actor: outsider)
      assert {:error, %Ash.Error.Forbidden{}} = Graph.unpin(first, actor: outsider)

      assert {:error, %Ash.Error.Forbidden{}} =
               Graph.pins(@fleet, :code, "general", actor: outsider)

      assert {:error, %Ash.Error.Forbidden{}} = Graph.pin(pin, actor: %Actors.System{})

      # A pin is its pinner's: another member neither lifts nor retitles it.
      hold!(2, @member)
      member = %Actors.Human{human_account_id: 2, wallet_addresses: [@member]}
      assert {:error, %Ash.Error.Forbidden{}} = Graph.unpin(first, actor: member)
      assert {:ok, kept} = Graph.pin(%{pin | title: "Mine now"}, actor: member)
      assert {kept.id, kept.human_account_id} == {first.id, 1}

      assert [%{title: "Read me", human_account_id: 1}] =
               Graph.pins!(@fleet, :code, "general", actor: member)

      assert :ok = Graph.unpin(first, actor: holder)
      assert [] = Graph.pins!(@fleet, :code, "general", actor: holder)

      # Lifting a pin already lifted, from another tab, finds no pin of theirs
      # to lift, and the page then reads afresh.
      assert {:error, %Ash.Error.Forbidden{}} = Graph.unpin(first, actor: holder)
    end

    test "another member's pin shows pinned, but only its pinner lifts it", %{conn: conn} do
      store!(%{"README.md" => "Hello"})
      hold!(2, @member)
      member = %Actors.Human{human_account_id: 2, wallet_addresses: [@member]}

      Graph.pin!(
        %{
          fleet_id: @fleet,
          project: "general",
          place: :code,
          target: "README.md",
          title: "README.md"
        },
        actor: member
      )

      {:ok, view, _html} = live(conn, @board <> "?place=code&project=general")

      for pin <- [
            ~s(#workspace-code-rows [data-file="README.md"] button),
            ~s(#workspace-code-pins-rows [data-pin="README.md"] button)
          ] do
        assert has_element?(
                 view,
                 pin <>
                   ~s([aria-pressed="true"][disabled][title="Pinned by another member"])
               )
      end

      {:ok, files, _html} = live(conn, Keyfleet.Code.files_path(@fleet, @repository, ""))

      assert has_element?(
               files,
               ~s(#workspace-file-rows [data-file="README.md"] button[aria-pressed="true"][disabled])
             )
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
      submit(@fleet, task, "https://example.com/draft", by: 4)
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
               "Key 4 submitted “Draft” for review.",
               "Key 3 linked “Draft” to “More revenue”, which it delivers on.",
               "Key 17 added the goal “More revenue”.",
               "Key 17 added the task “Draft”."
             ]

      assert has_element?(
               view,
               ~s(#workspace-activity a[href="#{Keyfleet.Fleets.path(@fleet)}?key=5"]),
               "Key 5"
             )

      assert has_element?(view, ~s(#workspace-activity a[href="#{item_path(task)}"]), "Draft")
    end

    test "a change to what the workspace keeps about an item names no field of it", %{
      conn: conn
    } do
      task = create(@fleet, "task", %{"title" => "Draft", "progress" => "todo"})
      [%{sys: sys}] = Graph.read_objects!(@fleet, [task], actor: %Actors.System{})

      event(@fleet, "patch.applied", %{
        "target" => task,
        "diff" => %{
          "progress" => %{"old" => "todo", "new" => "blocked"},
          "sys" => %{"old" => sys, "new" => sys}
        }
      })

      {:ok, view, _html} = live(conn, @board)

      assert Enum.take(activity(view), 1) == [
               "Keyfleet updated “Draft”: progress is now blocked."
             ]

      assert has_element?(
               view,
               ~s(#workspace-activity .workspace-detail time[datetime$="T12:03:00Z"])
             )

      assert has_element?(view, "#workspace-activity .workspace-detail time", "22 Sep")
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
      board = watch_reads(view)
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
      refute_receive {:workspace_read, ^board}, 1_300

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fixture", 2}
      )

      assert_receive {:workspace_read, ^board}, 2_000
      assert cards(view) == [task]
      assert hd(activity(view)) == "Key 17 added the task “New work”."
      refute render(view) =~ "Other fleet"

      {:ok, item, _html} = live(conn, item_path(task))
      page = watch_reads(item)
      edit(@fleet, task, %{"progress" => "doing"})

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fixture", 4}
      )

      assert_receive {:workspace_read, ^page}, 2_000
      assert has_element?(item, "#workspace-fields", "In progress")
      assert hd(history(item)) == "Key 17 updated “New work”: progress is now in progress."
    end

    test "a burst of changes is read once, a moment later, and old news not at all", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @board)
      board = watch_reads(view)
      task = create(@fleet, "task", %{"title" => "New work", "progress" => "todo"})

      for watermark <- [1, 2, 2] do
        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Graph.head_topic(@fleet),
          {:graph_head, @fleet, "log_fixture", watermark}
        )
      end

      refute_receive {:workspace_read, ^board}, 600
      assert_receive {:workspace_read, ^board}, 1_000
      refute_receive {:workspace_read, ^board}, 1_300
      assert cards(view) == [task]

      # What the page has already read, or less, is not read again.
      for watermark <- [2, 1] do
        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Graph.head_topic(@fleet),
          {:graph_head, @fleet, "log_fixture", watermark}
        )
      end

      refute_receive {:workspace_read, ^board}, 1_300

      # A copy of a fresh log is read however far along it is.
      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fresh", 1}
      )

      assert_receive {:workspace_read, ^board}, 2_000
    end
  end

  describe "deleting a project" do
    setup do
      open_log(@fleet)
      holder = %Actors.Human{human_account_id: 1, wallet_addresses: [@holder]}
      Keyfleet.Projects.start_project!(@fleet, 1, "lab", "Lab", actor: holder)
      Keyfleet.Projects.archive_project!(@fleet, 1, actor: holder)
      :ok
    end

    # Deleting takes the project's work with it, so Delete asks first in
    # Keyfleet's own window: Cancel keeps the project, and saying so deletes it.
    test "Delete asks first, Cancel keeps the project, and saying so deletes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @board <> "?project=lab")

      view |> element("#project-delete") |> render_click()
      assert has_element?(view, "#project-delete-dialog h2", "Delete Lab for good?")

      view |> render_hook("cancel_project_delete", %{})
      refute has_element?(view, "#project-delete-dialog")
      assert %{state: :archived} = lab()

      view |> element("#project-delete") |> render_click()
      view |> element("#project-delete-confirm") |> render_click()
      refute has_element?(view, "#project-delete-dialog")
      assert lab() == nil
    end
  end

  describe "a shown project's page" do
    setup do
      open_log(@fleet)

      start_project(@fleet, "lab", "Lab")
      |> Ash.Changeset.for_update(:shown, %{shown_to_everyone: true, key: 20},
        actor: %Actors.System{}
      )
      |> Ash.update!()

      # One goal more than the page lists, so its Goals part has more to see.
      for n <- 1..6,
          do: create(@fleet, "goal", %{"title" => "Goal #{n}", "outcome" => "O"}, project: "lab")

      goal =
        create(@fleet, "goal", %{"title" => "Try the new model", "outcome" => "O"},
          project: "lab"
        )

      task = create(@fleet, "task", %{"title" => "Draft the price"}, project: "lab")
      link(@fleet, task, goal, "implements")
      %{goal: goal, task: task}
    end

    # Costly failure: a visitor sent from a title or a workspace link to the
    # general Public place, when the workspace is only the members'.
    test "its titles and workspace links open the workspace for a member and are gone for anyone else",
         %{conn: conn, visitor: visitor, goal: goal, task: task} do
      {:ok, view, _html} = live(conn, "/syndicate/1/projects/lab")
      goal_path = KeyfleetWeb.WorkspacePage.item_path(@fleet, goal)
      task_path = KeyfleetWeb.WorkspacePage.item_path(@fleet, task)

      assert has_element?(
               view,
               ~s(#project-goals a.project-title[href="#{goal_path}"]),
               "Try the new model"
             )

      assert has_element?(
               view,
               ~s(#project-work a.project-title[href="#{task_path}"]),
               "Draft the price"
             )

      assert has_element?(
               view,
               ~s(#project-open a.project-title[href="#{task_path}"]),
               "Draft the price"
             )

      assert has_element?(
               view,
               ~s(.project-goal-tasks [data-item="#{task}"] a[href="#{task_path}"]),
               "Draft the price"
             )

      assert has_element?(view, ~s(#project-workspace[href="/syndicate/1/workspace?project=lab"]))

      assert has_element?(
               view,
               ~s(#project-goals a.project-more[href="/syndicate/1/workspace?project=lab"])
             )

      {:ok, view, _html} = live(visitor, "/syndicate/1/projects/lab")

      refute has_element?(view, "#project-workspace")
      refute has_element?(view, ".project-more")
      assert has_element?(view, "#project-goals span.project-title", "Try the new model")
      assert has_element?(view, "#project-work span.project-title", "Draft the price")
      assert has_element?(view, "#project-open span.project-title", "Draft the price")

      assert has_element?(
               view,
               ~s(.project-goal-tasks [data-item="#{task}"] span),
               "Draft the price"
             )

      refute has_element?(view, "#project-parts a.project-title")
      refute has_element?(view, "#project-parts .project-goal-tasks a")
    end
  end

  describe "another fleet's workspace" do
    test "never shows up in this one", %{conn: conn} do
      open_log(@fleet)
      open_log(@other)
      ours = create(@fleet, "task", %{"title" => "Ours", "progress" => "todo"}, id: "task#1")
      create(@other, "task", %{"title" => "Theirs", "progress" => "todo"}, id: "task#1")
      submit(@other, "task#1", "https://example.com/theirs")

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
      assert has_element?(item, ".workspace-heading h2", "Ours")
      assert has_element?(item, "p", "Nothing is linked to this yet.")
      assert history(item) == ["Key 17 added the task “Ours”."]
      refute render(item) =~ "Their"

      {:ok, missing, _html} = live(conn, "#{Keyfleet.Fleets.path(@fleet)}/workspace/goal%237")
      assert has_element?(missing, "h2", "This item isn’t in the workspace.")
    end
  end

  describe "how the work stands" do
    setup do
      open_log(@fleet)
      :ok
    end

    # Costly failure: a count that took in archived, achieved or another
    # fleet's or project's items would tell members the work stands where it
    # doesn't, in a line they read before anything else.
    test "the Project counts each goal and task where it stands, in both views",
         %{conn: conn} do
      create(@fleet, "goal", %{"title" => "Revenue"})
      edit(@fleet, create(@fleet, "goal", %{"title" => "Shipped"}), %{"status" => "achieved"})
      archive(@fleet, create(@fleet, "goal", %{"title" => "Old plan"}))
      starting_goal(@fleet, 1, %{"title" => "Nobody joined"})
      join(@fleet, starting_goal(@fleet, 2, %{"title" => "Someone joined"}))

      create(@fleet, "task", %{"title" => "Untaken"})
      create(@fleet, "task", %{"title" => "Taken", "assignee_key" => 4})
      create(@fleet, "task", %{"title" => "Doing", "progress" => "doing", "assignee_key" => 4})
      create(@fleet, "task", %{"title" => "Stuck", "progress" => "blocked", "assignee_key" => 5})
      submit(@fleet, create(@fleet, "task", %{"title" => "Waiting"}), "https://example.com/r1")

      accepted = create(@fleet, "task", %{"title" => "Accepted"})
      submit(@fleet, accepted, "https://example.com/r2")
      review(@fleet, accepted, "accept", by: 6)

      reproduced = create(@fleet, "task", %{"title" => "Reproduced"})
      submit(@fleet, reproduced, "https://example.com/r3")
      review(@fleet, reproduced, "accept", by: 6, reproduction: "passed")

      disputed = create(@fleet, "task", %{"title" => "Disputed"})
      submit(@fleet, disputed, "https://example.com/r4")
      review(@fleet, disputed, "dispute", by: 6)

      archive(@fleet, create(@fleet, "task", %{"title" => "Archived"}))

      open_log(@other)
      create(@other, "task", %{"title" => "Theirs"})

      for path <- [@board, @board <> "?view=graph"] do
        {:ok, view, _html} = live(conn, path)

        assert counts(view) == %{
                 open_goals: "2",
                 open_tasks: "2",
                 working: "1",
                 waiting_review: "1",
                 blocked: "2",
                 accepted: "2"
               }
      end

      # The Graph colours a reproduced task as done, as the count does.
      {:ok, view, _html} = live(conn, @board <> "?view=graph")
      assert has_element?(view, ~s([data-node="#{reproduced}"][data-tone="done"]), "Reproduced")
    end

    test "one project's counts leave out the others' work", %{conn: conn} do
      start_project(@fleet, "lab", "Lab")
      create(@fleet, "task", %{"title" => "In general"})
      create(@fleet, "task", %{"title" => "In the lab"}, project: "lab")
      create(@fleet, "goal", %{"title" => "Lab goal"}, project: "lab")

      {:ok, view, _html} = live(conn, @board <> "?project=lab")
      assert %{open_goals: "1", open_tasks: "1"} = counts(view)

      {:ok, view, _html} = live(conn, @board)
      assert %{open_goals: "1", open_tasks: "2"} = counts(view)
    end

    test "a visitor sees no counts", %{visitor: visitor} do
      create(@fleet, "task", %{"title" => "Untaken"})

      {:ok, view, _html} = live(visitor, @board)
      assert has_element?(view, "#workspace-members-only")
      refute has_element?(view, "#workspace-counts")
    end

    defp counts(view) do
      for standing <- [:open_goals, :open_tasks, :working, :waiting_review, :blocked, :accepted],
          into: %{} do
        figure =
          view
          |> element("#workspace-count-#{standing}")
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()
          |> String.trim()

        {standing, figure}
      end
    end
  end

  describe "the workspace's graph" do
    # Costly failure: the graph is a second way into the workspace, so a graph
    # that skipped the board's members-only rule would show anyone every item.
    test "draws this fleet's items for a member, and anyone else the members-only page",
         %{conn: conn, visitor: visitor} do
      open_log(@fleet)
      open_log(@other)
      create(@fleet, "task", %{"title" => "Ours", "progress" => "todo"}, id: "task#1")
      create(@other, "task", %{"title" => "Theirs", "progress" => "todo"}, id: "task#2")
      path = @board <> "?view=graph"

      {:ok, graph, _html} = live(conn, path)
      assert has_element?(graph, "#workspace-graph")
      assert render(graph) =~ "Ours"
      refute render(graph) =~ "Theirs"

      outsider = signed_in_as(visitor, "0x" <> String.duplicate("e", 40))

      for someone <- [visitor, outsider] do
        {:ok, refused, _html} = live(someone, path)
        assert has_element?(refused, "#workspace-members-only")
        refute has_element?(refused, "#workspace-graph")
        refute render(refused) =~ "Ours"
      end
    end
  end

  describe "one goal's map" do
    setup do
      open_log(@fleet)
      :ok
    end

    # Costly failure: a map that took in work from outside the goal, or left
    # out a fork or a review, would show a goal's work as other than it is.
    test "holds the goal, what is linked to it, and its tasks' outputs, reviews and forks",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue"})
      other_goal = create(@fleet, "goal", %{"title" => "Elsewhere"})
      task = create(@fleet, "task", %{"title" => "Draft the brief"})
      link(@fleet, task, goal, "implements")
      finding = create(@fleet, "finding", %{"title" => "Funds read briefs", "statement" => "S"})
      link(@fleet, task, finding, "produces")
      note = create(@fleet, "note", %{"title" => "Call notes", "body" => "B"})
      link(@fleet, note, goal, "references")
      fork = create(@fleet, "task", %{"title" => "Draft it shorter"}, by: 7)
      link(@fleet, fork, task, "forks")
      submit(@fleet, task, "https://example.com/brief")
      review = review(@fleet, task, "accept", by: 6)
      stray = create(@fleet, "task", %{"title" => "Unrelated"})
      link(@fleet, stray, other_goal, "implements")

      {:ok, view, _html} = live(conn, @board <> "?view=graph&goal=" <> URI.encode_www_form(goal))

      shown =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#workspace-graph-list > li")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-row"))
        |> Enum.sort()

      assert shown == Enum.sort([goal, task, finding, note, fork, review])
      assert view |> element("#workspace-graph-goal") |> render() =~ "Revenue"

      view |> element("#workspace-graph-every-goal") |> render_click()
      assert render(view) =~ "Unrelated"
    end

    # Costly failure: a fork shown as the owner's own work, or work hung
    # under the wrong task, would misstate who did what for the goal.
    test "stands on the goal's page as cards, each under the item it hangs from",
         %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue"})
      task = create(@fleet, "task", %{"title" => "Draft the brief", "assignee_key" => 4})
      link(@fleet, task, goal, "implements")
      finding = create(@fleet, "finding", %{"title" => "Funds read briefs", "statement" => "S"})
      link(@fleet, task, finding, "produces")
      fork = create(@fleet, "task", %{"title" => "Draft it shorter"}, by: 7)
      link(@fleet, fork, task, "forks")
      note = create(@fleet, "note", %{"title" => "Call notes", "body" => "B"})
      link(@fleet, note, goal, "references")

      {:ok, view, _html} = live(conn, KeyfleetWeb.WorkspacePage.item_path(@fleet, goal))

      branch = fn id ->
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s([data-item="#{id}"] > ol > li))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-item"))
      end

      top =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#workspace-goal-map-items > li")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-item"))

      assert top == [task, note]
      assert branch.(task) == [finding, fork]

      assert has_element?(
               view,
               ~s(#workspace-goal-map-items[phx-hook="MotionCascade"][data-variant="cascade"])
             )

      assert has_element?(view, ~s([data-item="#{fork}"][data-via="forks"]))
      assert has_element?(view, ~s([data-item="#{finding}"][data-via="produces"]))

      card = ~s([data-item="#{task}"] > .workspace-map-card)
      assert has_element?(view, card, "Key 4")
      assert has_element?(view, card <> " .workspace-map-standing", "To do")
      assert has_element?(view, ~s([data-item="#{fork}"] > .workspace-map-card), "Key 7")
    end

    test "steps from goal to goal on the stage, in the order they were added",
         %{conn: conn} do
      [first, second, third] =
        for title <- ["Revenue", "Hiring", "Research"],
            do: create(@fleet, "goal", %{"title" => title})

      task = create(@fleet, "task", %{"title" => "Draft the brief"})
      link(@fleet, task, second, "implements")
      submit(@fleet, task, "https://example.com/brief")
      map = fn goal -> @board <> "?view=graph&goal=" <> URI.encode_www_form(goal) end

      {:ok, view, _html} = live(conn, @board <> "?view=graph")
      assert has_element?(view, "#workspace-stage .workspace-stage-live", "Live")
      assert has_element?(view, "#workspace-step", "Every goal")
      assert has_element?(view, "#workspace-step", "3 goals")
      refute has_element?(view, "#workspace-step-back")

      view |> element("#workspace-step-on") |> render_click()
      assert_patch(view, map.(first))
      assert has_element?(view, "#workspace-step", "Goal 1 of 3")

      view |> element("#workspace-step-on") |> render_click()
      assert_patch(view, map.(second))
      assert has_element?(view, "#workspace-step", "Goal 2 of 3")
      assert has_element?(view, "#workspace-graph-goal", "Hiring")
      assert has_element?(view, "#workspace-step", "1 task")
      assert has_element?(view, "#workspace-step", "1 awaiting review")

      view |> element("#workspace-step-on") |> render_click()
      assert_patch(view, map.(third))
      refute has_element?(view, "#workspace-step-on")

      view |> element("#workspace-step-back") |> render_click()
      assert_patch(view, map.(second))
    end

    test "has small panels under the stage: workstream, Active Keys, Docs and Code",
         %{conn: conn} do
      doing =
        create(@fleet, "task", %{"title" => "Draft", "progress" => "doing", "assignee_key" => 4})

      waiting = create(@fleet, "task", %{"title" => "Price", "assignee_key" => 4})
      submit(@fleet, waiting, "https://example.com/price", by: 4)
      create(@fleet, "task", %{"title" => "Nobody's yet"})
      assert doing

      take_over_general()
      holder = %Actors.Human{human_account_id: 1, wallet_addresses: [@holder]}

      {:ok, _pin} =
        Graph.pin(
          %{
            fleet_id: @fleet,
            project: "general",
            place: :code,
            target: "README.md",
            title: "README.md"
          },
          actor: holder
        )

      {:ok, view, _html} = live(conn, @board <> "?view=graph")

      assert has_element?(view, "#workspace-instrument-work li", "submitted “Price” for review")

      assert has_element?(
               view,
               ~s(#workspace-instrument-keys [data-key="4"] [aria-label="1 in progress, 1 awaiting review, 0 done"])
             )

      assert view
             |> element("#workspace-instrument-keys")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("li")
             |> Enum.count() == 1

      assert has_element?(view, "#workspace-instrument-code li", "README.md")
      assert has_element?(view, "#workspace-instruments p", "Nothing pinned yet.")
    end

    test "the foot of the stage keeps its place before the first change", %{conn: conn} do
      {:ok, view, _html} = live(conn, @board <> "?view=graph")
      assert has_element?(view, "#workspace-stage #workspace-ticker")
      refute has_element?(view, "#workspace-ticker li")
    end

    test "the foot of the stage shows the newest change, and the next one once it comes",
         %{conn: conn} do
      create(@fleet, "task", %{"title" => "Draft"})
      {:ok, view, _html} = live(conn, @board <> "?view=graph")
      board = watch_reads(view)

      assert has_element?(view, "#workspace-ticker li", "Key 17 added the task “Draft”.")

      assert view
             |> element("#workspace-ticker")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("li")
             |> Enum.count() == 1

      create(@fleet, "note", %{"title" => "Call notes", "body" => "b"})

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Graph.head_topic(@fleet),
        {:graph_head, @fleet, "log_fixture", 3}
      )

      assert_receive {:workspace_read, ^board}, 2_000
      assert has_element?(view, "#workspace-ticker li", "Key 17 added the note “Call notes”.")
      refute has_element?(view, "#workspace-ticker li", "Draft")
    end

    test "an archived goal's page still hangs its work from it", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Old plan"})
      task = create(@fleet, "task", %{"title" => "Draft"})
      link(@fleet, task, goal, "implements")
      archive(@fleet, goal)

      {:ok, view, _html} = live(conn, KeyfleetWeb.WorkspacePage.item_path(@fleet, goal))

      assert has_element?(
               view,
               ~s(#workspace-goal-map-items > li[data-item="#{task}"][data-via="implements"])
             )
    end

    test "a step to a goal shows its whole map, whatever kind was picked", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue"})

      {:ok, view, _html} = live(conn, @board <> "?view=graph&type=task")
      view |> element("#workspace-step-on") |> render_click()
      assert_patch(view, @board <> "?view=graph&goal=" <> URI.encode_www_form(goal))
      assert has_element?(view, "#workspace-graph-goal", "Revenue")
    end

    test "is linked from the goal's page", %{conn: conn} do
      goal = create(@fleet, "goal", %{"title" => "Revenue"})

      {:ok, view, _html} = live(conn, KeyfleetWeb.WorkspacePage.item_path(@fleet, goal))
      view |> element("#workspace-goal-graph") |> render_click()

      assert_patch(
        view,
        @board <> "?view=graph&project=general&goal=" <> URI.encode_www_form(goal)
      )
    end

    test "an id that names no goal draws nothing, and the Board has no goal's map",
         %{conn: conn} do
      task = create(@fleet, "task", %{"title" => "Draft the brief"})

      {:ok, view, _html} = live(conn, @board <> "?view=graph&goal=goal%23999")
      assert has_element?(view, "#workspace-graph-empty")
      refute has_element?(view, "[data-node], [data-row]")

      for path <- [
            @board <> "?view=graph&goal=" <> URI.encode_www_form(task),
            @board <> "?goal=goal%231"
          ] do
        assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, path) end
      end
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
                   "/syndicate/1",
                   "/agents.md",
                   "/docs",
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

      assert page |> LazyHTML.query(".workspace-heading h2") |> LazyHTML.text() ==
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

  describe "what agents send and cite" do
    setup do
      open_log(@fleet)
      :ok
    end

    # A background run's saved result, the address `notebooks_result`
    # answers, showed as a plain link (Grok Bot, 18 October 2026).
    test "a background run's saved result is shown as a saved notebook result, as a version's is",
         %{conn: conn} do
      for source <- ["run_01M539TC83WX2ZRQFZB4VHH178", "ver_01M539TC83WX2ZRQFZB4VHH178"] do
        uri =
          Keyfleet.Notebooks.result_url(@fleet, "nb-0123456789abcdef", source, 1_792_186_134_702)

        evidence = create(@fleet, "evidence", %{"title" => "Saved result", "source_uri" => uri})
        {:ok, view, _html} = live(conn, item_path(evidence))
        assert has_element?(view, ~s(a[data-notebook-result][href="#{uri}"]))
      end
    end

    # Several agents write as one Key; a reader has to see which one added an item.
    test "an item an agent added names the agent beside its Key, on the board and on its page",
         %{conn: conn} do
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!("0x" <> String.duplicate("a1", 20))
      )

      note = create(@fleet, "note", %{"title" => "Standup", "body" => "Ship it."})

      {:ok, board, _html} = live(conn, @board)
      assert card_text(board, note) =~ "Added by Mate (Key 17)"

      {:ok, _item, html} = live(conn, item_path(note))
      assert html =~ "Mate (Key 17)"
    end

    test "a goal an agent joined names it, on the board, on its page and in the activity",
         %{conn: conn} do
      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!("0x" <> String.duplicate("a1", 20))
      )

      goal = create(@fleet, "goal", %{"title" => "Ship", "outcome" => "It ships."})
      join(@fleet, goal, by: 18)

      {:ok, board, _html} = live(conn, @board)
      assert {"Joined", "1"} in facts(board, goal)
      assert "Mate (Key 18) joined “Ship”." in activity(board)

      {:ok, item, _html} = live(conn, item_path(goal))
      assert has_element?(item, "#workspace-fields", "Mate (Key 18)")
    end

    # Three agents pushed as one Key, and every push read as the Key alone.
    test "a push an agent sent names the agent beside its Key, on the board and on the commit",
         %{conn: conn} do
      agent = "0x" <> String.duplicate("c", 40)

      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(agent)
      )

      hash = CodeHistory.hash(1)
      store!(%{"README.md" => "Hello"}, [CodeHistory.commit(1)])

      Keyfleet.Code.record_pushes(
        @fleet,
        "general",
        %{token_id: 1, wallet: @holder, acting_agent_wallet: agent},
        [%{ref: "refs/heads/main", head: hash}]
      )

      {:ok, board, _html} = live(conn, @board <> "?place=code&project=general")
      assert has_element?(board, "#code-pushes", "Mate (Key 1) sent changes to main")

      [job] = all_enqueued(worker: Keyfleet.Code.Sent)
      assert :ok = perform_job(Keyfleet.Code.Sent, job.args)

      {:ok, commit, _html} = live(conn, Keyfleet.Code.commit_path(@fleet, @repository, hash))
      assert has_element?(commit, "#workspace-commit-byline", "Mate (Key 1)")
      assert has_element?(commit, "#workspace-commit-byline", "sent changes to main")
    end

    test "the History reads thirty commits a page, each with what cites it, and a commit shows its changes",
         %{conn: conn} do
      commits = Enum.map(32..1//-1, &CodeHistory.commit/1)
      store!(%{"steps/3.txt" => "step 3"}, commits)
      newest = CodeHistory.hash(32)

      task =
        create(@fleet, "task", %{
          "title" => "Take step 3",
          "progress" => "doing",
          "commit_ref" =>
            KeyfleetWeb.WorkspacePage.commit_url(@fleet, @repository, CodeHistory.hash(3))
        })

      {:ok, history, _html} = live(conn, Keyfleet.Code.history_path(@fleet, @repository))
      assert length(rows(history)) == 30
      assert has_element?(history, "#code-history-#{newest}", "Step 32")
      refute has_element?(history, "#workspace-history-newer")

      older = Keyfleet.Code.history_path(@fleet, @repository, newest, 2)
      assert has_element?(history, ~s(#workspace-history-older[href="#{older}"]))

      {:ok, history, _html} = live(conn, older)
      assert length(rows(history)) == 2
      assert has_element?(history, "#code-history-#{CodeHistory.hash(1)}", "Step 1")
      assert has_element?(history, "#workspace-history-newer")
      assert has_element?(history, "#workspace-history-latest")

      # Step 3 is on the first page, cited by its task.
      {:ok, history, _html} = live(conn, Keyfleet.Code.history_path(@fleet, @repository))

      assert has_element?(
               history,
               ~s(#code-history-#{CodeHistory.hash(3)} a[href="#{item_path(task)}"]),
               "Take step 3"
             )

      {:ok, commit, _html} =
        live(conn, Keyfleet.Code.commit_path(@fleet, @repository, CodeHistory.hash(3)))

      assert has_element?(commit, "#workspace-commit-subject", "Step 3")
      assert has_element?(commit, "#workspace-commit-message", "Why step 3 was taken.")
      assert has_element?(commit, "#workspace-commit-changes", "steps/3.txt")
      assert has_element?(commit, "#workspace-commit-changes", "step 3")

      assert has_element?(
               commit,
               "#workspace-commit-parents",
               String.slice(CodeHistory.hash(2), 0, 12)
             )
    end

    # Page 300 of a long history offered Older, which led to a page that
    # doesn't exist.
    test "the last History page a reader can open offers no Older page, and says where the rest is",
         %{conn: conn} do
      commits = Enum.map(9_001..1//-1, &CodeHistory.commit/1)
      store!(%{}, commits)
      newest = CodeHistory.hash(9_001)

      {:ok, before_last, _html} =
        live(conn, Keyfleet.Code.history_path(@fleet, @repository, newest, 299))

      last = Keyfleet.Code.history_path(@fleet, @repository, newest, 300)
      assert has_element?(before_last, ~s(#workspace-history-older[href="#{last}"]))
      refute has_element?(before_last, "#workspace-history-end")

      {:ok, history, _html} = live(conn, last)
      assert length(rows(history)) == 30
      assert has_element?(history, "#code-history-#{CodeHistory.hash(2)}")
      refute has_element?(history, "#workspace-history-older")
      assert has_element?(history, "#workspace-history-end")
      assert has_element?(history, "#workspace-history-newer")
    end

    test "a commit written with no message still has words to open it by", %{conn: conn} do
      commit = %{CodeHistory.commit(1) | "message" => "\n"}
      store!(%{}, [commit])

      {:ok, history, _html} = live(conn, Keyfleet.Code.history_path(@fleet, @repository))
      link = text(history, "#code-history-#{commit["hash"]} .code-history-subject")
      assert String.trim(link) != ""

      {:ok, page, _html} =
        live(conn, Keyfleet.Code.commit_path(@fleet, @repository, commit["hash"]))

      assert String.trim(text(page, "#workspace-commit-subject")) != ""
    end

    test "a commit the repository doesn't have says so", %{conn: conn} do
      store!(%{}, [CodeHistory.commit(1)])

      {:ok, commit, _html} =
        live(conn, Keyfleet.Code.commit_path(@fleet, @repository, CodeHistory.hash(2)))

      assert has_element?(commit, "#workspace-commit-not-sent")
    end

    # A visitor who followed a commit link an agent posted saw no sign of
    # the commit and no way in (Grok Bot, 18 October 2026).
    test "a commit page someone can't read still names the commit, and offers Sign in to a visitor",
         %{visitor: visitor} do
      hash = String.duplicate("5", 40)
      path = Keyfleet.Code.commit_path(@fleet, @repository, hash)

      {:ok, signed_out, _html} = live(visitor, path)
      assert has_element?(signed_out, "#workspace-commit-page code", hash)
      assert has_element?(signed_out, "#workspace-commit-sign-in")

      outsider = signed_in_as(visitor, "0x" <> String.duplicate("e", 40))
      {:ok, signed_in, _html} = live(outsider, path)
      assert has_element?(signed_in, "#workspace-commit-page code", hash)
      refute has_element?(signed_in, "#workspace-commit-sign-in")
    end
  end

  describe "a workspace not ready to read" do
    test "says so", %{conn: conn} do
      {:ok, view, html} = live(conn, @board)

      assert html =~ @notice

      assert has_element?(view, "#workspace-unavailable", "Nothing in this workspace yet.")

      refute has_element?(view, "#workspace-cards")

      {:ok, item, _html} = live(conn, "#{Keyfleet.Fleets.path(@fleet)}/workspace/task%231")

      assert has_element?(item, "#workspace-unavailable", "Nothing in this workspace yet.")
    end

    test "at an address no fleet's pages are at is not found, as the fleet's own page is",
         %{conn: conn} do
      for path <- [
            "/app/fleets/no_such_fleet/workspace",
            "/app/fleets/no_such_fleet/workspace/task%231",
            "/app/fleets/no_such_fleet",
            "/app/fleets/#{@fleet}/workspace",
            "/app/fleets/#{@fleet}",
            "/syndicate/2/workspace",
            "/syndicate/2",
            "/no-such-type/1"
          ] do
        assert get(conn, path).status == 404
      end
    end
  end

  test "the fleet's page leads to its workspace", %{conn: conn} do
    {:ok, view, _html} = live(conn, "#{Keyfleet.Fleets.path(@fleet)}")

    assert has_element?(view, ~s(#fleet-tab-workspace[href="#{@board}"]), "Workspace")
  end

  defp item_path(id), do: KeyfleetWeb.WorkspacePage.item_path(@fleet, id)

  # The fleet's repository, holding `files` by their paths, answered as the
  # code store answers: a folder's names, or one file's bytes.
  defp store!(files, commits \\ []) do
    Keyfleet.Code.record_repository!(@repository, "z6MkOwner", actor: %Actors.System{})
    serve_code(files, commits)
  end

  # The commits a History page lists.
  defp rows(history),
    do:
      history
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#code-history > li")
      |> Enum.to_list()

  # The code store, holding `files` and the history `commits` (newest
  # first) from now on.
  defp serve_code(files, commits \\ []) do
    test = self()

    Req.Test.stub(Keyfleet.Code.NodeClient, fn conn ->
      send(test, {:store, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

      ["", "api", "v1", "repos", "z6MkOwner", @fleet, read | segments] =
        String.split(conn.request_path, "/")

      path = Enum.map_join(segments, "/", &URI.decode/1)

      case read do
        "commits" -> CodeHistory.answer(conn, commits, segments)
        "tree" -> Req.Test.json(conn, %{"entries" => entries(files, path), "path" => path})
        "blob" when is_map_key(files, path) -> Plug.Conn.send_resp(conn, 200, files[path])
        "blob" -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  # Each entry as the store answers it: its `git ls-tree -l` line.
  defp entries(files, folder) do
    prefix = if folder == "", do: "", else: folder <> "/"

    files
    |> Enum.filter(fn {path, _bytes} -> String.starts_with?(path, prefix) end)
    |> Enum.map(fn {path, bytes} ->
      case path |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) do
        [name] ->
          %{
            "mode" => "100644",
            "type" => "blob",
            "hash" => "b10b",
            "name" => name,
            "size" => byte_size(bytes)
          }

        [name, _rest] ->
          %{"mode" => "040000", "type" => "tree", "hash" => "7ee", "name" => name, "size" => nil}
      end
    end)
    |> Enum.uniq()
  end

  # The fleet's notebook hub, answering a listing of the project's notebooks
  # with what `answer` makes of its query, or nothing at all when `:down`.
  # Tasks of the goal, each citing one of the notebooks, the last made first.
  defp cite!(goal, project, notebooks) do
    for notebook <- notebooks do
      task =
        create(@fleet, "task", %{
          "title" => "Uses " <> notebook,
          "progress" => "doing",
          "notebook_ref" => Keyfleet.Notebooks.notebook_url(@fleet, project, notebook)
        })

      link(@fleet, task, goal, "implements")
    end
  end

  defp meta(id, title, status) do
    %{
      "id" => id,
      "title" => title,
      "description" => "",
      "status" => status,
      "created_at" => "2025-01-02T09:00:00Z",
      "tags" => []
    }
  end

  defp collect_asked(asked \\ []) do
    receive do
      {:asked, id} -> collect_asked([id | asked])
    after
      0 -> asked
    end
  end

  defp hub!(project_id, answer) do
    hub =
      KeyfleetWeb.SignedAgentHelpers.serve!(:hub, fn conn, _opts ->
        conn |> Plug.Conn.fetch_query_params() |> hub_answer(project_id, answer)
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))

    @fleet
    |> Keyfleet.Projects.project!(Keyfleet.Projects.general(), actor: %Actors.System{})
    |> Keyfleet.Projects.record_space!(project_id, actor: %Actors.System{})
  end

  defp hub_answer(conn, _project_id, :down), do: Plug.Conn.send_resp(conn, 503, "")

  defp hub_answer(conn, project_id, answer) do
    case conn.request_path do
      "/api/v1/projects/" <> ^project_id <> "/notebooks" ->
        Req.Test.json(conn, %{
          "success" => true,
          "data" => %{"items" => answer.(conn.query_params), "next_cursor" => nil}
        })

      # One notebook, asked for by its id.
      "/api/v1/projects/" <> ^project_id <> "/notebooks/" <> id ->
        notebook_answer(conn, answer.({:notebook, id}))
    end
  end

  defp notebook_answer(conn, nil),
    do: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"success" => false})

  defp notebook_answer(conn, :down), do: Plug.Conn.send_resp(conn, 503, "")

  defp notebook_answer(conn, {:slow, meta}) do
    Process.sleep(500)
    Req.Test.json(conn, %{"success" => true, "data" => %{"meta" => meta}})
  end

  defp notebook_answer(conn, meta),
    do: Req.Test.json(conn, %{"success" => true, "data" => %{"meta" => meta}})

  defp claims(pass) do
    [_header, payload, _signature] = String.split(pass, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode()
  end

  defp text(view, selector),
    do:
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()

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

  # The fleet's project `lab`, or nil once it is deleted.
  defp lab, do: Keyfleet.Projects.project!(@fleet, "lab", actor: %Actors.System{})

  # Records `wallet` as the owner of the fleet's Key `token_id`.
  # Key 1 takes over the fleet's archived `general`, so it takes new work.
  defp take_over_general do
    Keyfleet.Projects.take_over_project!(@fleet, 1, Keyfleet.Projects.general(),
      actor: %Actors.Human{human_account_id: 1, wallet_addresses: [@holder]}
    )
  end

  defp hold!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: token_id - 1
      },
      actor: %Actors.System{}
    )
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

  defp goals(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-goals li")
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

  defp work(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-goal-map-items li")
    |> LazyHTML.attribute("data-item")
  end

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

  # Each row of a list, as the parts a person reads in it.
  defp rows(view, list) do
    html = view |> render() |> LazyHTML.from_fragment()

    for row <- LazyHTML.query(html, list <> " > li") do
      for part <- [".workspace-kind", ".workspace-row-title", ".workspace-row-meta"],
          node <- LazyHTML.query(row, part),
          do: node |> LazyHTML.text() |> squish()
    end
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # A page position as the site writes one: the sort values it follows.
  defp keyset(values), do: values |> :erlang.term_to_binary() |> Base.encode64()

  # Tells this test each time the open page reads the workspace again, naming
  # the page, whose process it returns.
  defp watch_reads(view) do
    id = "workspace-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:keyfleet, :repo, :query],
      &__MODULE__.report_read/4,
      {self(), view.pid}
    )

    on_exit(fn -> :telemetry.detach(id) end)
    view.pid
  end

  @doc false
  def report_read(_event, _measurements, %{source: "graph_cursors"}, {test, page}) do
    if self() == page, do: send(test, {:workspace_read, page})
  end

  def report_read(_event, _measurements, _meta, _config), do: :ok
end
