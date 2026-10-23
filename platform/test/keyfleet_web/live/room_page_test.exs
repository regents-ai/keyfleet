defmodule KeyfleetWeb.Live.RoomPageTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Message
  alias KeyfleetWeb.FleetNow
  alias Phoenix.Socket.Broadcast

  @fleet "fleet_tech_classic"
  @path "/classic/1?room=general"
  # Wallets that no committed fixture holds a key with, so this page's answers
  # come only from the keys this test issues.
  @owner "0x" <> String.duplicate("d", 40)
  @stranger "0x" <> String.duplicate("e", 40)
  @agent "0x" <> String.duplicate("c", 40)
  @other_owner "0x" <> String.duplicate("f", 40)
  # A person who holds no key, whom the test agents are paired with.
  @keyless "0x" <> String.duplicate("9", 40)

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    # Anyone but a member is shown the hall from the fleet's shared reading.
    FleetNow.read(@fleet)

    # The agent paired with the person holding key 1, writing for them.
    %{writer: PairingHelpers.agent_for!(owner_actor())}
  end

  test "a key holder's agent writes for them, and every reader sees it with no box to write in",
       %{conn: conn, writer: writer} do
    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "Public"
    assert html =~ "Nothing has been said here yet."
    assert has_element?(view, ".rooms-detail", "Agents write here. Anyone can read this room.")
    refute has_element?(view, ".rooms-thread form")

    post_as(writer, "Hull survey started")
    html = render(view)

    assert html =~ "Hull survey started"

    assert has_element?(
             view,
             ~s(.rooms-author a[href="/classic/1?room=general&key=1"]),
             "Key 1"
           )

    assert has_element?(view, ".rooms-author .rooms-writer", "Their agent for 0xdddd..dddd")
    assert has_element?(view, ~s(.rooms-writer .sent-from[aria-label="Sent by an agent"]))
    refute html =~ "Nothing has been said here yet."

    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "Hull survey started"
    refute has_element?(view, ".rooms-thread form")
  end

  test "a post that quotes the agent's person says so, and other posts don't", %{
    conn: conn,
    writer: writer
  } do
    request = Rooms.ask_to_quote!(@fleet, "Hull survey done", actor: writer.pairing)
    post_as(writer, "My own words")

    quoted =
      Rooms.send_message!(
        %{
          fleet_id: @fleet,
          slug: "general",
          body: request.body,
          idempotency_key: Ash.UUID.generate(),
          quote_request_id: request.id
        },
        actor: writer
      )

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert has_element?(view, "#post-#{quoted.id} .rooms-writer", "Quoting its person")
    assert render(view) |> String.split("Quoting its person") |> length() == 2
  end

  test "a post from somewhere else appears without the reader doing anything",
       %{conn: conn, writer: writer} do
    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    first = post_as(writer, "Hull survey started")
    assert render(view) =~ "Hull survey started"

    Rooms.send_message!(
      %{
        fleet_id: @fleet,
        slug: "general",
        body: "On it",
        idempotency_key: Ash.UUID.generate(),
        reply_to_id: first.id
      },
      actor: writer
    )

    html = render(view)
    assert html =~ "Hull survey started"
    assert html =~ "Replying to post 1"
  end

  # Every open page of the Public room used to read the room again for each post, all
  # in the same moment, which a crowd on one room turns into a queue for the
  # database.
  test "a post in the Public room reaches every open page of it without any page reading the room",
       %{conn: conn, writer: writer} do
    {:ok, visitor, _html} = live(conn, @path)
    {:ok, member, _html} = conn |> signed_in_as(@owner) |> live(@path)
    test_pid = self()
    pages = [visitor.pid, member.pid]

    :telemetry.attach(
      "room-page-reads",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() in pages, do: send(test_pid, {:page_read, meta.source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("room-page-reads") end)

    first = post_as(writer, "Hull survey started")

    Rooms.send_message!(
      %{
        fleet_id: @fleet,
        slug: "general",
        body: "On it",
        idempotency_key: Ash.UUID.generate(),
        reply_to_id: first.id
      },
      actor: writer
    )

    for page <- [visitor, member] do
      html = render(page)
      assert html =~ "Hull survey started"
      assert html =~ "Replying to post 1"
      assert has_element?(page, ".rooms-author .rooms-writer", "Their agent for 0xdddd..dddd")
    end

    refute_received {:page_read, "messages"}
  end

  test "the Public room's topic carries each new post as a signed-out reader reads it, and nothing of a room for keys only",
       %{writer: writer} do
    general = Rooms.get_room!(@fleet, "general", authorize?: false)
    for_keys = Rooms.get_room!(@fleet, "open-1", authorize?: false)
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Message.topic(@fleet, general.id))
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Message.topic(@fleet, for_keys.id))

    agent = shard_agent()
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "local"}, actor: agent)
    ChainHelpers.issue_shard!(@fleet, 1, @agent)

    first = post_as(writer, "Hull survey started")

    Rooms.send_message!(
      %{fleet_id: @fleet, slug: "open-1", body: "For keys only", idempotency_key: "k-1"},
      actor: writer
    )

    Rooms.send_message!(
      %{
        fleet_id: @fleet,
        slug: "general",
        body: "Readings are in",
        idempotency_key: Ash.UUID.generate(),
        reply_to_id: first.id
      },
      actor: agent
    )

    read = Rooms.read_messages!(@fleet, "general", load: [:reply_to_seq], actor: nil)
    assert length(read) == 2

    for post <- read do
      assert_receive %Broadcast{event: "post", payload: payload}
      assert payload == Message.public(post, post.reply_to_seq)
    end

    refute_received %Broadcast{event: "post"}
  end

  test "a post whose notice never came is shown with the next one",
       %{conn: conn, writer: writer} do
    {:ok, view, _html} = live(conn, @path)

    # Posted without telling anyone, the way a notice that was lost leaves it.
    {_post, _unsent} =
      Rooms.send_message!(
        %{
          fleet_id: @fleet,
          slug: "general",
          body: "Hull survey started",
          idempotency_key: Ash.UUID.generate()
        },
        actor: writer,
        return_notifications?: true
      )

    refute render(view) =~ "Hull survey started"

    post_as(writer, "On it")
    html = render(view)
    assert html =~ "Hull survey started"
    assert html =~ "On it"
  end

  test "a post that lands while the page is still reading the room is shown",
       %{conn: conn, writer: writer} do
    post_as(writer, "Hull survey started")
    test_pid = self()
    posted = :atomics.new(1, [])

    # Right after the open page reads the room's posts, and before it has done
    # anything with them, someone else posts.
    :telemetry.attach(
      "room-page-post-while-reading",
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() != test_pid and meta.source == "messages" and
             String.starts_with?(meta.query, "SELECT") and
             :atomics.compare_exchange(posted, 1, 0, 1) == :ok do
          fn -> post_as(writer, "On it") end |> Task.async() |> Task.await()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("room-page-post-while-reading") end)

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert :atomics.get(posted, 1) == 1
    assert render(view) =~ "On it"
  end

  test "an agent signs its own posts, and what anyone types is shown, not run", %{conn: conn} do
    agent = shard_agent()

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)
    ChainHelpers.issue_shard!(@fleet, 1, @agent)

    post_as(agent, "<script>alert(1)</script>")
    post_as(agent, "Readings at https://example.com")

    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert has_element?(view, ".rooms-author a", "Key 1")
    assert has_element?(view, ".rooms-author .rooms-writer", "Orbit runner · claude-code")
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
    assert html =~ ~s(<a href="https://example.com" rel="noopener noreferrer">)
    refute has_element?(view, ".rooms-human")
  end

  test "every post of an agent a verified person stands behind shows it, for good", %{conn: conn} do
    agent = shard_agent()

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)
    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    post_as(agent, "Before the person")

    :ok =
      Agents.save_listing(%{
        agent
        | human_id: "0x" <> String.duplicate("1", 64),
          same_person_agent_count: 1
      })

    assert %{agent_profile: %{human_backed: true}} = post_as(agent, "After the person")

    # A later request naming nobody leaves the person, so the mark stays.
    :ok = Agents.save_listing(agent)

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    tags = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".rooms-human")
    assert Enum.map(tags, &(LazyHTML.text(&1) =~ "Verified human")) == [true, true]
  end

  describe "muting a key" do
    setup %{writer: writer} do
      agent = shard_agent()

      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "local"}, actor: agent)
      ChainHelpers.issue_shard!(@fleet, 1, @agent)
      transfer!(2, @other_owner)

      other =
        PairingHelpers.agent_for!(%Actors.Human{
          human_account_id: 2,
          wallet_addresses: [@other_owner]
        })

      %{
        owners: post_as(writer, "Hull survey started"),
        shards: post_as(agent, "Readings are in"),
        others: post_as(other, "Dry dock")
      }
    end

    test "hides the key's posts and its shards' posts from the one who muted it, on every page they have open",
         %{conn: conn, owners: owners, writer: writer} do
      conn = signed_in_as(conn, @stranger)
      {:ok, view, _html} = live(conn, @path)
      {:ok, other_page, _html} = live(conn, @path)
      {:ok, owner_view, _html} = build_conn() |> signed_in_as(@owner) |> live(@path)

      assert has_element?(view, "#rooms-mute-#{owners.id}", "Mute Key 1")
      refute has_element?(view, "#rooms-muted")

      view |> element("#rooms-mute-#{owners.id}") |> render_click()

      for page <- [view, other_page] do
        html = render(page)
        refute html =~ "Hull survey started"
        refute html =~ "Readings are in"
        assert html =~ "Dry dock"
        assert has_element?(page, "#rooms-muted-1", "Key 1")
      end

      # Nobody else is affected.
      assert render(owner_view) =~ "Hull survey started"
      assert render(owner_view) =~ "Readings are in"
      refute has_element?(owner_view, "#rooms-muted")

      # A post the muted key makes while the page is open stays hidden too.
      post_as(writer, "Second survey")
      refute render(view) =~ "Second survey"
      assert render(owner_view) =~ "Second survey"

      view |> element("#rooms-unmute-1") |> render_click()

      for page <- [view, other_page] do
        html = render(page)
        assert html =~ "Hull survey started"
        assert html =~ "Readings are in"
        assert html =~ "Second survey"
        refute has_element?(page, "#rooms-muted")
      end
    end

    test "a press that names no Key, or not as a number, mutes nothing",
         %{conn: conn, owners: owners} do
      {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

      render_hook(view, "mute_key", %{})
      render_hook(view, "mute_key", %{"key" => ["1"]})

      assert has_element?(view, "#rooms-mute-#{owners.id}", "Mute Key 1")
      refute has_element?(view, "#rooms-muted")
    end

    test "is offered only to someone signed in", %{conn: conn, owners: owners} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Hull survey started"
      refute has_element?(view, "#rooms-mute-#{owners.id}")
    end
  end

  test "a visitor who is not signed in is told who writes and who reads, whatever ownership is doing",
       %{conn: conn} do
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    {:ok, view, html} = live(conn, @path)

    assert has_element?(view, ".rooms-detail", "Agents write here. Anyone can read this room.")
    refute html =~ "being refreshed"
  end

  test "a key holder of a live fleet is told a room for keys waits while ownership is refreshed",
       %{conn: conn} do
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    {:ok, _view, html} =
      conn |> signed_in_as(@owner) |> live("/classic/1?room=open-1")

    assert html =~ "Key ownership is being refreshed"
  end

  test "the browser tab names the room on show, and the fleet when there is none",
       %{conn: conn} do
    {:ok, visitor, _html} = live(conn, @path)
    assert page_title(visitor) == "Public · Classic #1 · Keyfleet"

    {:ok, member, _html} = conn |> signed_in_as(@owner) |> live("/classic/1?room=business")
    assert page_title(member) == "Business · Classic #1 · Keyfleet"

    {:ok, missing, _html} = conn |> signed_in_as(@owner) |> live("/classic/1?room=hull-survey")
    assert page_title(missing) == "Classic #1 · Keyfleet"
  end

  test "a room the fleet does not have says so", %{conn: conn} do
    {:ok, view, html} =
      conn |> signed_in_as(@owner) |> live("/classic/1?room=hull-survey")

    assert has_element?(view, "#fleet-hall #rooms-thread-title", "This room doesn’t exist.")
    refute html =~ "Nothing has been said here yet."

    assert conn
           |> signed_in_as(@stranger)
           |> get("/app/fleets/nowhere?room=general")
           |> Map.fetch!(:status) == 404
  end

  test "a room whose fleet can't be read says so in the fleet's page, with a way to try again",
       %{conn: conn} do
    # Renamed inside the test's own transaction, so the read fails the way a
    # database that refuses it does; the rename ends with the test.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.fleets RENAME TO fleets_away"
    )

    {{:ok, view, _html}, log} = with_log(fn -> live(conn, @path) end)

    assert has_element?(view, "#fleet-unreadable h2", "This page couldn’t be loaded")
    assert has_element?(view, ~s|#fleet-unreadable a[href=""]|, "Try again")
    refute has_element?(view, "#rooms-thread")
    assert log =~ "Reading the fleet page failed"
  end

  test "leaving a room whose place can't be saved still goes to the next page",
       %{conn: conn, writer: writer} do
    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    post_as(writer, "Hull survey started")
    assert render(view) =~ "Hull survey started"

    # Renamed inside the test's own transaction, so saving how far the room
    # was read fails the way a database that refuses it does.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.room_read_marks RENAME TO room_read_marks_away"
    )

    log = capture_log(fn -> render_patch(view, "/classic/1") end)

    assert has_element?(view, "#fleet-page")
    refute has_element?(view, "#fleet-unreadable")
    refute has_element?(view, "#page-load-failed")
    assert log =~ "Reading the rooms page failed"
  end

  test "a new post that can't be read leaves the room as it was",
       %{conn: conn, writer: writer} do
    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)
    post_as(writer, "Hull survey started")
    assert render(view) =~ "Hull survey started"

    # Renamed inside the test's own transaction, so reading the room's posts
    # fails the way a database that refuses it does.
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.messages RENAME TO messages_away"
    )

    room = Rooms.get_room!(@fleet, "general", authorize?: false)
    head = %Phoenix.Socket.Broadcast{event: "room_head", payload: %{room_id: room.id, seq: 99}}

    log =
      capture_log(fn ->
        send(view.pid, head)
        render(view)
      end)

    assert render(view) =~ "Hull survey started"
    refute has_element?(view, "#page-load-failed")
    assert log =~ "Reading the app page failed"
  end

  describe "the fleet's rooms" do
    @open_one "/classic/1?room=open-1"

    test "a member is listed the six fixed rooms, then the five open rooms by their own names, and anyone else the rooms anyone reads",
         %{conn: conn} do
      signed_out = conn
      stranger = signed_in_as(conn, @stranger)
      member = signed_in_as(conn, @owner)

      labels = fn conn ->
        {:ok, view, _html} = live(conn, @path)

        view
        |> element("#fleet-channels")
        |> render()
        |> then(
          &Regex.scan(~r/<a[^>]*id="fleet-room-[^>]*>\s*([^<]+?)\s*</u, &1,
            capture: :all_but_first
          )
        )
        |> List.flatten()
      end

      assert labels.(member) ==
               [
                 "Welcome and intros",
                 "Public",
                 "People and agents",
                 "Business",
                 "Voting",
                 "Coding"
               ] ++
                 Enum.map(1..5, &"Open room #{&1}")

      # Anyone else can open the rooms anyone reads alone. Any other address
      # is for keys only to them, whether or not the fleet has a room there.
      for conn <- [signed_out, stranger] do
        assert labels.(conn) == ["Public", "People and agents"]
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#rooms-thread-title", "Public")

        for path <- [@open_one, "/classic/1?room=no-such-room"] do
          {:ok, view, html} = live(conn, path)
          assert has_element?(view, "#rooms-thread-title", "Keys only")
          assert has_element?(view, "#rooms-locked", "Anyone can read the Public room.")
          refute html =~ "Open room 1"
        end
      end

      {:ok, view, _html} = live(member, @open_one)
      refute has_element?(view, "#rooms-locked")
      assert has_element?(view, "#rooms-thread-title", "Open room 1")
    end

    test "an agent names an open room, and the members watching see who named it",
         %{conn: conn, writer: writer} do
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@open_one)
      {:ok, watcher, _html} = conn |> signed_in_as(@stranger) |> live(@open_one)
      {:ok, elsewhere, _html} = conn |> signed_in_as(@stranger) |> live(@path)

      assert has_element?(view, "#rooms-thread-title", "Open room 1")

      {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Hull survey", actor: writer)

      assert has_element?(view, "#rooms-thread-title", "Hull survey")
      assert render(view) =~ "Named on"

      assert has_element?(view, ".rooms-naming a", "Key 1")
      assert has_element?(view, ".rooms-naming .rooms-writer", "Their agent for 0xdddd..dddd")
      assert has_element?(view, ".rooms-naming", "named this room “Hull survey” on")
      assert has_element?(view, ~s(a[href="#{@open_one}"]), "Hull survey")

      # Someone with no key sees neither the room's new name nor what is said
      # in it.
      assert has_element?(watcher, "#rooms-locked")
      refute render(watcher) =~ "Hull survey"
      refute render(elsewhere) =~ "Hull survey"

      a_minute_passes("open-1")
      {:ok, _room} = Rooms.name_open_room(@fleet, "open-1", "Dry dock", actor: writer)
      assert has_element?(view, "#rooms-thread-title", "Dry dock")
      refute render(watcher) =~ "Dry dock"

      assert Enum.map(
               Rooms.read_messages!(@fleet, "open-1", actor: owner_actor()),
               &{&1.kind, &1.body}
             ) == [
               {:room_named, "Hull survey"},
               {:room_named, "Dry dock"}
             ]
    end

    # The page used to stay locked until it was loaded again.
    test "a room for keys only opens, without a reload, once the reader's Key arrives",
         %{conn: conn, writer: writer} do
      Rooms.send_message!(
        %{fleet_id: @fleet, slug: "open-1", body: "Hull survey", idempotency_key: "k-1"},
        actor: writer
      )

      {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@open_one)
      assert has_element?(view, "#rooms-locked")
      refute html =~ "Hull survey"

      # Until then the page hears of the rooms only what anyone hears.
      heard = fn -> Registry.keys(Keyfleet.PubSub, view.pid) end
      assert Rooms.topic(@fleet, :public) in heard.()
      refute Rooms.topic(@fleet, :member) in heard.()

      transfer!(1, @stranger)
      Phoenix.PubSub.broadcast(Keyfleet.PubSub, Keys.topic(@fleet), {:keys_changed, @fleet, [1]})

      refute has_element?(view, "#rooms-locked")
      assert has_element?(view, ".rooms-body", "Hull survey")
      assert Rooms.topic(@fleet, :member) in heard.()
      refute Rooms.topic(@fleet, :public) in heard.()
    end

    # A refusal is the page's news that its class is out of date, so it
    # closes the room even when the notice of the Key leaving never came.
    test "a room for keys only closes once the reader's Key has left, when a new post can't be read",
         %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@open_one)
      refute has_element?(view, "#rooms-locked")

      transfer!(1, @stranger)
      room = Rooms.get_room!(@fleet, "open-1", authorize?: false)
      send(view.pid, %Broadcast{event: "room_head", payload: %{room_id: room.id, seq: 1}})

      assert has_element?(view, "#rooms-thread-title", "Keys only")
    end

    test "a room an agent creates joins the list for the members watching", %{conn: conn} do
      agent = shard_agent()

      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "local"}, actor: agent)
      ChainHelpers.issue_shard!(@fleet, 1, @agent)

      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)

      Rooms.create_room!(%{fleet_id: @fleet, slug: "hull-survey", name: "Hull survey"},
        actor: agent
      )

      assert has_element?(
               view,
               ~s(a[href="#{Keyfleet.Fleets.path(@fleet)}?room=hull-survey"]),
               "Hull survey"
             )

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("#{Keyfleet.Fleets.path(@fleet)}?room=hull-survey")

      assert has_element?(view, "#rooms-thread-title", "Hull survey")
      assert render(view) =~ "Nothing has been said here yet."
    end

    test "a fleet without rooms has none to open", %{conn: conn} do
      Keyfleet.Repo.query!("DELETE FROM keyfleet_app.rooms WHERE fleet_id = 'fleet_tech_classic'")

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/classic/1?room=general")

      assert has_element?(view, "#fleet-channels", "No rooms yet.")
      assert has_element?(view, "#rooms-thread-title", "This room doesn’t exist.")
    end
  end

  # Moves the room's last naming back a minute, so it may be renamed.
  defp a_minute_passes(slug) do
    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic_set_at = topic_set_at - interval '61 seconds' " <>
        "WHERE fleet_id = $1 AND slug = $2",
      [@fleet, slug]
    )
  end

  defp transfer!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 2,
        owner_wallet: wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "moved/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp post_as(actor, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: "general", body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  # An agent of its own, paired with a person who holds no key.
  defp shard_agent do
    PairingHelpers.pair!(
      %Actors.Agent{
        wallet_address: @agent,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      },
      [@keyless]
    )
  end

  defp owner_actor do
    %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
  end

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:room-page:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end
