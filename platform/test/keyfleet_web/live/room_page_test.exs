defmodule KeyFleetWeb.Live.RoomPageTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.Accounts
  alias KeyFleet.Actors
  alias KeyFleet.Agents
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Rooms

  @fleet "fibonacci_syndicate"
  @path "/app/fleets/fibonacci_syndicate/rooms/general"
  # Wallets that no committed fixture holds a key with, so this page's answers
  # come only from the keys this test issues.
  @owner "0x" <> String.duplicate("d", 40)
  @stranger "0x" <> String.duplicate("e", 40)
  @operator "0x" <> String.duplicate("c", 40)
  @composer "#rooms-composer"

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_core_rooms!()

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 0,
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
    assert html =~ "0xdddd…dddd"
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
      [:key_fleet, :repo, :query],
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
    agent = %Actors.Agent{wallet_address: @operator, chain_id: 8453, audience: "keyfleet"}
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)
    request = Keys.request_pairing!(@fleet, 1, %{}, actor: agent)
    Keys.approve_pairing!(request, %{}, actor: owner_actor())

    post_as(agent, "<script>alert(1)</script>")
    post_as(agent, "Readings at https://example.com")

    {:ok, _view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "Orbit runner · claude-code"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
    assert html =~ ~s(<a href="https://example.com" rel="noopener noreferrer">)
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
      conn |> signed_in_as(@owner) |> live("/app/fleets/fibonacci_syndicate/rooms/hull-survey")

    assert has_element?(view, ".rooms-kicker", "Keyfleet Syndicate")
    assert html =~ "This room doesn’t exist."
    refute html =~ "Nothing has been said here yet."
    refute has_element?(view, @composer)

    {:ok, _view, html} =
      conn |> signed_in_as(@stranger) |> live("/app/fleets/nowhere/rooms/general")

    assert html =~ "This fleet doesn’t exist."
  end

  describe "level and topic rooms" do
    # Syndicate keys other suites commit outside the sandbox would count as
    # sold, so the levels are read on the Cascade fleet.
    @cascade "fibonacci_cascade"
    @opener "#rooms-opener"
    @early "0x" <> String.duplicate("b", 40)
    @later "0x" <> String.duplicate("f", 40)

    setup do
      ChainHelpers.seed_cursor!(@cascade)
      # Keys 1 and 2 are level 1's, keys 3 and 4 level 2's; key 5 is not sold.
      sell!(1, @early)
      sell!(2, @early)
      sell!(3, @owner)
      sell!(4, @later)
      :ok
    end

    test "a level's room says who posts there, and offers the box only to them", %{conn: conn} do
      level_two = "/app/fleets/#{@cascade}/rooms/level-2"

      {:ok, view, html} = conn |> signed_in_as(@owner) |> live(level_two)
      assert has_element?(view, "#rooms-thread-title", "Level 2")
      assert html =~ "Level 2 keys post here from the start."
      assert html =~ "Keys from earlier levels join once every Level 2 key is sold."
      assert html =~ "Later levels never post here."
      assert has_element?(view, ~s(a[href="/app/fleets/#{@cascade}/rooms/level-1"]), "Level 1")
      refute has_element?(view, ~s(a[href="/app/fleets/#{@cascade}/rooms/level-3"]))
      # A level's room is named after its level, so it carries no tag.
      refute has_element?(view, ".rooms-list .rooms-tag")
      assert has_element?(view, @composer)

      view |> form(@composer, post: %{body: "Level two here"}) |> render_submit()
      assert Enum.map(Rooms.read_messages!(@cascade, "level-2"), & &1.body) == ["Level two here"]

      {:ok, view, html} = conn |> signed_in_as(@early) |> live(level_two)
      refute has_element?(view, @composer)
      assert html =~ "Only the people who can post in Level 2"
      assert html =~ "Level two here"

      # Once key 5 is sold, level 1's keys post in level 2 as well.
      sell!(5, @owner)
      {:ok, view, _html} = conn |> signed_in_as(@early) |> live(level_two)
      assert has_element?(view, @composer)

      # A level that opens while the page is up joins its list of rooms.
      sell!(6, @later)
      assert has_element?(view, ~s(a[href="/app/fleets/#{@cascade}/rooms/level-3"]), "Level 3")

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/#{@cascade}/rooms/level-1")

      refute has_element?(view, @composer)
    end

    test "a refused post is judged again by the room's own rule", %{conn: conn} do
      # Key 6 is a level 3 key, which never posts in level 2.
      sell!(6, @owner)

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/#{@cascade}/rooms/level-2")

      assert has_element?(view, @composer)
      transfer!(3, @stranger)

      view |> form(@composer, post: %{body: "Still here?"}) |> render_submit()
      refute has_element?(view, @composer)
      assert Rooms.read_messages!(@cascade, "level-2") == []
    end

    test "a key holder names a topic room and its address, for the fleet or a level they post in",
         %{conn: conn} do
      general = "/app/fleets/#{@cascade}/rooms/general"
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(general)
      {:ok, watcher, _html} = conn |> signed_in_as(@early) |> live(general)

      assert has_element?(view, @opener)

      assert has_element?(
               view,
               ~s(#{@opener} option[value=""]),
               "Anyone holding this fleet’s keys"
             )

      assert has_element?(view, ~s(#{@opener} option[value="2"]), "The same people as Level 2")
      refute has_element?(view, ~s(#{@opener} option[value="1"]))

      # The address is suggested from the name as it is typed.
      view |> form(@opener, topic: %{name: "Hull Survey: phase 2!"}) |> render_change()
      assert has_element?(view, ~s(#rooms-opener-address[value="hull-survey-phase-2"]))

      view |> form(@opener, topic: %{level: "2"}) |> render_submit()
      assert_patch(view, "/app/fleets/#{@cascade}/rooms/hull-survey-phase-2")

      assert has_element?(view, "#rooms-thread-title", "Hull Survey: phase 2!")
      assert render(view) =~ "Level 2 keys post here from the start."

      assert has_element?(
               view,
               ~s(a[href="/app/fleets/#{@cascade}/rooms/hull-survey-phase-2"] + .rooms-tag),
               "Level 2"
             )

      assert has_element?(view, @composer)

      # The form is empty again, and everyone watching sees the new room.
      assert has_element?(view, ~s(#rooms-opener-name[value=""]))
      assert has_element?(view, ~s(#rooms-opener-address[value=""]))

      assert has_element?(
               watcher,
               ~s(a[href="/app/fleets/#{@cascade}/rooms/hull-survey-phase-2"])
             )

      # An address the person writes stays theirs while they change the name.
      view |> form(@opener, topic: %{name: "Galley"}) |> render_change()
      view |> form(@opener, topic: %{address: "mess-deck"}) |> render_change()
      view |> form(@opener, topic: %{name: "Galley and mess"}) |> render_change()
      assert has_element?(view, ~s(#rooms-opener-address[value="mess-deck"]))

      view |> form(@opener, topic: %{level: ""}) |> render_submit()
      assert_patch(view, "/app/fleets/#{@cascade}/rooms/mess-deck")

      refute has_element?(
               view,
               ~s(a[href="/app/fleets/#{@cascade}/rooms/mess-deck"] + .rooms-tag)
             )

      assert Enum.map(topics(), &{&1.slug, &1.name, &1.level}) == [
               {"mess-deck", "Galley and mess", nil},
               {"hull-survey-phase-2", "Hull Survey: phase 2!", 2}
             ]

      shape =
        "An address uses lowercase letters, numbers and single dashes, like hull-survey, " <>
          "and can’t be general, planning, work or a level’s address."

      name =
        "Choose another name of up to 80 characters, on one line, that isn’t General, " <>
          "Planning, Work or a level’s name."

      for {topic, refusal} <- [
            {{"Early", "early", "1"},
             "Only the people who can post in that level can open a room that follows it."},
            {{"Mess", "mess-deck", ""},
             "That address is already in use in this fleet. Try another."},
            {{"Mess", "Mess", ""}, shape},
            {{"Mess", "mess deck", ""}, shape},
            {{"Mess", "", ""}, shape},
            {{"Mess", "general", ""}, shape},
            {{"Mess", "level-2", ""}, shape},
            {{"General", "general-talk", ""}, name},
            {{"  level 2 ", "level-talk", ""}, name},
            {{"Mess\ndeck", "mess-two", ""}, name},
            {{"Mess \u202Edeck", "mess-two", ""}, name},
            {{"", "mess-two", ""}, name},
            {{"Mess", "mess-two", "21"}, "Choose who can post from the list."}
          ] do
        {topic_name, address, level} = topic

        html =
          render_submit(view, "open_room", %{
            "topic" => %{"name" => topic_name, "address" => address, "level" => level}
          })

        assert html =~ refusal, inspect(topic)
      end

      # What was typed stays in the form after a refusal.
      assert has_element?(view, ~s(#rooms-opener-address[value="mess-two"]))

      # A form missing a field is refused, and the page carries on.
      for params <- [%{}, %{"topic" => %{"name" => "Mess"}}, %{"topic" => "Mess"}] do
        assert render_submit(view, "open_room", params) =~
                 "That room couldn’t be opened. Try again."

        render_change(view, "edit_room_opener", params)
      end

      assert length(topics()) == 2
    end

    test "someone holding keys of several levels is offered each level once", %{conn: conn} do
      # Key 5 completes level 2, which key 1 and 2's holder then reaches as well.
      sell!(5, @early)

      {:ok, view, _html} =
        conn |> signed_in_as(@early) |> live("/app/fleets/#{@cascade}/rooms/general")

      options = view |> element("#rooms-opener-level") |> render()

      assert Regex.scan(~r/<option value="(\d*)"/, options, capture: :all_but_first) ==
               [[""], ["1"], ["2"]]
    end

    test "someone holding none of the fleet's keys opens no room", %{conn: conn} do
      galley = %{"topic" => %{"name" => "Galley", "address" => "galley", "level" => ""}}

      {:ok, view, _html} =
        conn |> signed_in_as(@stranger) |> live("/app/fleets/#{@cascade}/rooms/general")

      refute has_element?(view, @opener)
      render_submit(view, "open_room", galley)
      assert topics() == []

      # A key that changes hands after the page was drawn takes the right with it.
      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/#{@cascade}/rooms/general")

      transfer!(3, @stranger)

      assert render_submit(view, "open_room", galley) =~
               "Only the people holding this fleet’s keys can open a room."

      assert topics() == []

      {:ok, view, _html} = live(conn, "/app/fleets/#{@cascade}/rooms/general")
      refute has_element?(view, @opener)
    end

    test "a fleet that has all its topic rooms says so", %{conn: conn} do
      for n <- 1..100 do
        Rooms.create_topic_room!(%{fleet_id: @cascade, slug: "topic-#{n}", name: "Topic #{n}"},
          actor: owner_actor()
        )
      end

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/#{@cascade}/rooms/general")

      assert view
             |> form(@opener, topic: %{name: "Galley", address: "galley", level: ""})
             |> render_submit() =~
               "This fleet already has as many topic rooms as it can hold."
    end

    test "a fleet without rooms offers no room to open", %{conn: conn} do
      ChainHelpers.seed_cursor!("fleet_tech_accelerant")
      sell!(1, @owner, "fleet_tech_accelerant")

      KeyFleet.Repo.query!(
        "DELETE FROM keyfleet_app.rooms WHERE fleet_id = 'fleet_tech_accelerant'"
      )

      {:ok, view, html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_accelerant/rooms/general")

      assert html =~ "This fleet doesn’t exist."
      refute has_element?(view, @opener)
    end

    test "a Classic fleet has no level rooms and offers no level to follow", %{conn: conn} do
      ChainHelpers.seed_cursor!("fleet_tech_classic")
      sell!(1, @owner, "fleet_tech_classic")

      {:ok, view, _html} =
        conn |> signed_in_as(@owner) |> live("/app/fleets/fleet_tech_classic/rooms/general")

      refute has_element?(view, ~s(a[href*="/rooms/level-"]))
      assert has_element?(view, @opener)
      refute has_element?(view, ~s(#{@opener} option[value="1"]))
    end
  end

  defp topics,
    do: for(%{kind: :topic} = room <- Rooms.list_rooms!("fibonacci_cascade"), do: room)

  defp sell!(token_id, wallet, fleet \\ "fibonacci_cascade") do
    Keys.record_epoch!(
      %{
        fleet_id: fleet,
        token_id: token_id,
        ownership_epoch: 0,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    :ok = Rooms.ensure_level_rooms(fleet)
  end

  defp transfer!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: "fibonacci_cascade",
        token_id: token_id,
        ownership_epoch: 1,
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
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1
      },
      actor: %Actors.System{}
    )
  end
end
