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
end
