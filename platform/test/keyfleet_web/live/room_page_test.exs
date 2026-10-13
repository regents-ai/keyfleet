defmodule KeyfleetWeb.Live.RoomPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Rooms

  @fleet "fleet_tech_classic"
  @path "/app/fleets/fleet_tech_classic/rooms/general"
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

    # The agent paired with the person holding key 1, writing for them.
    %{writer: PairingHelpers.agent_for!(owner_actor())}
  end

  test "a key holder's agent writes for them, and every reader sees it with no box to write in",
       %{conn: conn, writer: writer} do
    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "General"
    assert html =~ "Nothing has been said here yet."
    assert html =~ "Agents write here. Anyone can read this room."
    refute has_element?(view, ".rooms-thread form")

    post_as(writer, "Hull survey started")
    html = render(view)

    assert html =~ "Hull survey started"

    assert has_element?(
             view,
             ~s(.rooms-author a[href="/app/fleets/fleet_tech_classic?key=1"]),
             "Key 1"
           )

    assert has_element?(view, ".rooms-author .rooms-writer", "Their agent for 0xdddd..dddd")
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

      assert has_element?(view, "#rooms-mute-#{owners.id}", "Mute Key #1")
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

    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Agents write here. Anyone can read this room."
    refute html =~ "being refreshed"
  end

  test "a key holder of a live fleet is told a room for keys waits while ownership is refreshed",
       %{conn: conn} do
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    {:ok, _view, html} =
      conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_classic/rooms/open-1")

    assert html =~ "Key ownership is being refreshed"
  end

  test "a room the fleet does not have says so", %{conn: conn} do
    {:ok, view, html} =
      conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_classic/rooms/hull-survey")

    assert has_element?(view, ".rooms-kicker", "Classic #1")
    assert html =~ "This room doesn’t exist."
    refute html =~ "Nothing has been said here yet."

    {:ok, _view, html} =
      conn |> signed_in_as(@stranger) |> live("/app/fleets/nowhere/rooms/general")

    assert html =~ "This fleet doesn’t exist."
  end

  describe "the fleet's rooms" do
    @open_one "/app/fleets/fleet_tech_classic/rooms/open-1"

    test "a member is listed the five fixed rooms, then the five open rooms by their own names, and anyone else General alone",
         %{conn: conn} do
      signed_out = conn
      stranger = signed_in_as(conn, @stranger)
      member = signed_in_as(conn, @owner)

      labels = fn conn ->
        {:ok, view, _html} = live(conn, @path)

        view
        |> element(".rooms-list")
        |> render()
        |> then(&Regex.scan(~r/<a[^>]*>\s*([^<]+?)\s*</u, &1, capture: :all_but_first))
        |> List.flatten()
      end

      assert labels.(member) ==
               ["Welcome and intros", "General", "Business", "Voting", "Coding"] ++
                 Enum.map(1..5, &"Open room #{&1}")

      # Anyone else is shown General alone. Any other address is for keys
      # only to them, whether or not the fleet has a room there.
      for conn <- [signed_out, stranger] do
        assert labels.(conn) == ["General"]

        for path <- [@open_one, "/app/fleets/fleet_tech_classic/rooms/no-such-room"] do
          {:ok, view, html} = live(conn, path)
          assert has_element?(view, "#rooms-locked #rooms-thread-title", "Keys only")
          assert has_element?(view, "#rooms-locked", "Anyone can read General.")
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
      assert render(view) =~ "Named by 0xdddd..dddd on"

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

      transfer!(1, @stranger)
      Phoenix.PubSub.broadcast(Keyfleet.PubSub, Keys.topic(@fleet), {:keys_changed, @fleet, [1]})

      refute has_element?(view, "#rooms-locked")
      assert has_element?(view, ".rooms-body", "Hull survey")
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
               ~s(a[href="/app/fleets/#{@fleet}/rooms/hull-survey"]),
               "Hull survey"
             )

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/#{@fleet}/rooms/hull-survey")

      assert has_element?(view, "#rooms-thread-title", "Hull survey")
      assert render(view) =~ "Nothing has been said here yet."
    end

    test "a fleet without rooms says it does not exist", %{conn: conn} do
      Keyfleet.Repo.query!("DELETE FROM keyfleet_app.rooms WHERE fleet_id = 'fleet_tech_classic'")

      {:ok, _view, html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_classic/rooms/general")

      assert html =~ "This fleet doesn’t exist."
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
