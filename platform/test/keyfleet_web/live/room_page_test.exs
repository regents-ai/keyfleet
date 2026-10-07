defmodule KeyfleetWeb.Live.RoomPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Rooms

  @fleet "fleet_tech_classic"
  @path "/app/fleets/fleet_tech_classic/rooms/general"
  # Wallets that no committed fixture holds a key with, so this page's answers
  # come only from the keys this test issues.
  @owner "0x" <> String.duplicate("d", 40)
  @stranger "0x" <> String.duplicate("e", 40)
  @agent "0x" <> String.duplicate("c", 40)
  @other_owner "0x" <> String.duplicate("f", 40)
  @composer "#rooms-composer"

  setup do
    Fleets.bootstrap_catalog!()
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

    :ok
  end

  test "a key holder says something and the room shows it", %{conn: conn} do
    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "General"
    assert html =~ "Nothing has been said here yet."
    assert has_element?(view, @composer)

    html = view |> form(@composer, post: %{body: "Hull survey started"}) |> render_submit()

    assert html =~ "Hull survey started"

    assert has_element?(
             view,
             ~s(.rooms-author a[href="/app/fleets/fleet_tech_classic?key=1"]),
             "Key 1"
           )

    assert has_element?(view, ".rooms-author .rooms-writer", "0xdddd..dddd")

    refute html =~ "Nothing has been said here yet."
    assert Enum.map(Rooms.read_messages!(@fleet, "general"), & &1.body) == ["Hull survey started"]
  end

  test "someone with no key of the fleet reads the room and is offered no box", %{conn: conn} do
    post_as_owner("Hull survey started")

    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "Hull survey started"
    assert html =~ "Everyone can read."
    refute has_element?(view, @composer)

    assert render_submit(view, "send_message", %{"post" => %{"body" => "Hello"}}) =~
             "can post here"

    assert Enum.map(Rooms.read_messages!(@fleet, "general"), & &1.body) == ["Hull survey started"]
  end

  test "a post from somewhere else appears without the reader doing anything", %{conn: conn} do
    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    first = post_as_owner("Hull survey started")
    assert render(view) =~ "Hull survey started"

    Rooms.send_message!(
      %{
        fleet_id: @fleet,
        slug: "general",
        body: "On it",
        idempotency_key: Ash.UUID.generate(),
        reply_to_id: first.id
      },
      actor: owner_actor()
    )

    html = render(view)
    assert html =~ "Hull survey started"
    assert html =~ "Replying to post 1"
  end

  test "a post that lands while the page is still reading the room is shown", %{conn: conn} do
    post_as_owner("Hull survey started")
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
          fn -> post_as_owner("On it") end |> Task.async() |> Task.await()
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
    agent = %Actors.Agent{
      wallet_address: @agent,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

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
    agent = %Actors.Agent{
      wallet_address: @agent,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

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
    setup do
      agent = %Actors.Agent{
        wallet_address: @agent,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      }

      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "local"}, actor: agent)
      ChainHelpers.issue_shard!(@fleet, 1, @agent)
      transfer!(2, @other_owner)

      %{
        owners: post_as_owner("Hull survey started"),
        shards: post_as(agent, "Readings are in"),
        others:
          post_as(
            %Actors.Human{human_account_id: 2, wallet_addresses: [@other_owner]},
            "Dry dock"
          )
      }
    end

    test "hides the key's posts and its shards' posts from the one who muted it, on every page they have open",
         %{conn: conn, owners: owners} do
      conn = signed_in_as(conn, @stranger)
      {:ok, view, _html} = live(conn, @path)
      {:ok, other_page, _html} = live(conn, @path)
      {:ok, owner_view, _html} = build_conn() |> signed_in_as(@owner) |> live(@path)

      assert has_element?(view, "#rooms-mute-#{owners.id}", "Mute key #1")
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
      post_as_owner("Second survey")
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

  test "a visitor who is not signed in is told who can post, whatever ownership is doing",
       %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Everyone can read."
    refute html =~ "being refreshed"
  end

  test "a key holder of a live fleet is told posting waits while ownership is refreshed",
       %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "Key ownership is being refreshed"
    refute has_element?(view, @composer)
  end

  test "a room the fleet does not have says so and offers no box", %{conn: conn} do
    {:ok, view, html} =
      conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_classic/rooms/hull-survey")

    assert has_element?(view, ".rooms-kicker", "Keyfleet Classic")
    assert html =~ "This room doesn’t exist."
    refute html =~ "Nothing has been said here yet."
    refute has_element?(view, @composer)

    {:ok, _view, html} =
      conn |> signed_in_as(@stranger) |> live("/app/fleets/nowhere/rooms/general")

    assert html =~ "This fleet doesn’t exist."
  end

  describe "the fleet's rooms" do
    @open_one "/app/fleets/fleet_tech_classic/rooms/open-1"
    @namer "#rooms-namer"

    test "a fleet lists its five fixed rooms, then its five open rooms by their own names",
         %{conn: conn} do
      signed_out = conn
      stranger = signed_in_as(conn, @stranger)
      member = signed_in_as(conn, @owner)

      for conn <- [signed_out, stranger, member] do
        {:ok, view, _html} = live(conn, @path)

        labels =
          view
          |> element(".rooms-list")
          |> render()
          |> then(&Regex.scan(~r/<a[^>]*>\s*([^<]+?)\s*<\/a>/u, &1, capture: :all_but_first))
          |> List.flatten()

        assert labels ==
                 ["Welcome and intros", "General", "Business", "Voting", "Coding"] ++
                   Enum.map(1..5, &"Open room #{&1}")

        # A fixed room takes no name.
        refute has_element?(view, @namer)
      end

      # Only a member is asked to name an open room.
      for conn <- [signed_out, stranger] do
        {:ok, view, html} = live(conn, @open_one)
        assert has_element?(view, "#rooms-thread-title", "Open room 1")
        refute has_element?(view, @namer)
        refute html =~ "Name this room"
      end

      {:ok, view, _html} = live(member, @open_one)
      assert has_element?(view, "label[for=rooms-namer-topic]", "Name this room")
    end

    test "a key holder names an open room, and everyone watching sees who named it",
         %{conn: conn} do
      {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@open_one)
      {:ok, watcher, _html} = conn |> signed_in_as(@stranger) |> live(@open_one)
      {:ok, elsewhere, _html} = conn |> signed_in_as(@stranger) |> live(@path)

      assert has_element?(view, "#rooms-thread-title", "Open room 1")
      assert html =~ "Name this room"
      refute has_element?(watcher, @namer)

      html = view |> form(@namer, room: %{topic: "Hull survey"}) |> render_submit()

      assert has_element?(view, "#rooms-thread-title", "Hull survey")
      assert html =~ "Named by 0xdddd..dddd on"

      assert has_element?(view, ".rooms-naming a", "Key 1")
      assert has_element?(view, ".rooms-naming .rooms-writer", "0xdddd..dddd")
      assert has_element?(view, ".rooms-naming", "named this room “Hull survey” on")

      assert has_element?(view, ~s(a[href="#{@open_one}"]), "Hull survey")
      assert has_element?(view, "#rooms-namer-topic[value='']")
      assert has_element?(view, "label[for=rooms-namer-topic]", "Rename this room")

      assert has_element?(watcher, "#rooms-thread-title", "Hull survey")
      assert has_element?(watcher, ".rooms-naming", "named this room “Hull survey”")
      assert render(watcher) =~ "Named by 0xdddd..dddd on"
      assert has_element?(elsewhere, ~s(a[href="#{@open_one}"]), "Hull survey")

      # A room is renamed at most once a minute.
      assert view |> form(@namer, room: %{topic: "Dry dock"}) |> render_submit() =~
               "This room was renamed a moment ago. Try again in a minute."

      assert has_element?(watcher, "#rooms-thread-title", "Hull survey")
      a_minute_passes("open-1")

      view |> form(@namer, room: %{topic: "Dry dock"}) |> render_submit()
      assert has_element?(watcher, "#rooms-thread-title", "Dry dock")

      assert Enum.map(Rooms.read_messages!(@fleet, "open-1"), &{&1.kind, &1.body}) == [
               {:room_named, "Hull survey"},
               {:room_named, "Dry dock"}
             ]
    end

    test "a name that breaks the rules is refused and stays in the box", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@open_one)
      rule = "Choose a name of up to 80 characters, on one line, using only visible characters."
      taken = "That name is already another room’s name in this fleet."

      {:ok, _room} = Rooms.name_open_room(@fleet, "open-2", "Dry dock", actor: owner_actor())

      for topic <- [
            "",
            "   ",
            String.duplicate("h", 81),
            "Hull\nsurvey",
            "Hull\u200Bsurvey",
            "Hull\u2028survey",
            "Hull \u202Esurvey"
          ] do
        html = render_submit(view, "name_room", %{"room" => %{"topic" => topic}})
        assert html =~ rule, inspect(topic)
        refute html =~ taken
      end

      for topic <- [" coding ", "DRY dock", "Ｃｏｄｉｎｇ"] do
        html = render_submit(view, "name_room", %{"room" => %{"topic" => topic}})
        assert html =~ taken, inspect(topic)
        refute html =~ rule
      end

      assert has_element?(view, ~s(#rooms-namer-topic[value="Ｃｏｄｉｎｇ"]))

      # A form missing its field is refused, and the page carries on.
      for params <- [%{}, %{"room" => %{}}, %{"room" => "Hull"}] do
        assert render_submit(view, "name_room", params) =~
                 "That room couldn’t be named. Try again."
      end

      assert %{topic: nil, head_seq: 0} = Rooms.get_room!(@fleet, "open-1")
    end

    test "only the people holding the fleet's keys name an open room", %{conn: conn} do
      naming = %{"room" => %{"topic" => "Mine now"}}

      {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@open_one)
      refute has_element?(view, @namer)

      assert render_submit(view, "name_room", naming) =~
               "Only the people holding this fleet’s keys can name a room."

      {:ok, view, _html} = live(conn, @open_one)
      refute has_element?(view, @namer)

      # A key that changes hands after the page was drawn takes the right with it.
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@open_one)
      assert has_element?(view, @namer)
      transfer!(1, @stranger)

      assert render_submit(view, "name_room", naming) =~
               "Only the people holding this fleet’s keys can name a room."

      refute has_element?(view, @namer)
      refute has_element?(view, @composer)
      assert %{topic: nil} = Rooms.get_room!(@fleet, "open-1")
    end

    test "naming waits while key ownership is refreshed", %{conn: conn} do
      deploy!()
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@open_one)
      assert has_element?(view, @namer)

      ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)

      assert render_submit(view, "name_room", %{"room" => %{"topic" => "Hull"}}) =~
               "Key ownership is being refreshed"

      assert %{topic: nil} = Rooms.get_room!(@fleet, "open-1")
    end

    test "a fixed room keeps its name", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)

      assert render_submit(view, "name_room", %{"room" => %{"topic" => "Hull"}}) =~
               "That room couldn’t be named. Try again."

      assert has_element?(view, "#rooms-thread-title", "General")
    end

    test "a room an agent creates joins the list for everyone watching", %{conn: conn} do
      agent = %Actors.Agent{
        wallet_address: @agent,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      }

      Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "local"}, actor: agent)
      ChainHelpers.issue_shard!(@fleet, 1, @agent)

      {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

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

      assert has_element?(view, @composer)
      refute has_element?(view, @namer)
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

  defp post_as_owner(body), do: post_as(owner_actor(), body)

  defp post_as(actor, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: "general", body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
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

  defp deploy! do
    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 1,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        shards_address: "0x" <> String.duplicate("6", 40),
        usdc_address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end
end
