defmodule KeyfleetWeb.Live.WorldlineLiveTest do
  # A fleet's Worldline: the picture takes its events once the page is live,
  # older ones as it asks and new ones as they happen; the list shows the
  # same events as links, a page at a time.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, PairingHelpers, Rooms}
  alias Keyfleet.Repo

  @fleet "fleet_tech_classic"
  @path "/classic/1/worldline"
  @holder "0x" <> String.duplicate("d", 40)

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    epoch!(1, @holder)
    %{writer: PairingHelpers.agent_for!(human(@holder))}
  end

  test "a signed-out reader's picture takes the public posts, each linking to its room",
       %{conn: conn, writer: writer} do
    post!(writer, "general", "Hull survey started")
    post!(writer, "coding", "Hull plates welded")

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#fleet-tab-worldline[aria-current=page]")
    assert has_element?(view, "#worldline-stage[phx-hook=Worldline]")
    # The planets are drawn for everyone; the polls only for members.
    for trail <- ~w(workspace code notebooks chat proposals keys),
        do: assert(has_element?(view, ~s(#worldline-legend li[data-trail="#{trail}"])))

    refute has_element?(view, ~s(#worldline-legend li[data-trail="polls"]))

    assert_push_event(view, "worldline:page", %{events: events, older: false, now: now})
    assert is_integer(now)

    assert [
             %{
               trail: "room:general",
               kind: :post,
               who: "Key 1",
               title: "Hull survey started",
               path: "/classic/1?room=general",
               live: true,
               place: place
             }
           ] = Enum.filter(events, &(&1.kind == :post))

    # Its place in its room, which sets its row on the room's line.
    assert is_integer(place) and place > 0
  end

  test "the picture reads the page before as it asks, and hears a post as it happens",
       %{conn: conn, writer: writer} do
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    for n <- 0..104, do: line!("general", DateTime.add(hour_ago, -n))

    {:ok, view, _html} = live(conn, @path)
    assert_push_event(view, "worldline:page", %{events: newest, older: true})
    assert Enum.count(newest, &(&1.kind == :post)) == 100

    render_hook(view, "worldline_older", %{})
    assert_reply(view, %{events: older, older: false})
    # The five lines left over; the fleet's own older actions (its Key's
    # purchase, at the chain's clock) may come with them.
    assert Enum.count(older, &(&1.kind == :post)) == 5
    assert Enum.max_by(older, & &1.at).at < Enum.min_by(newest, & &1.at).at

    # What is heard is read as the newest of its source; the picture keeps
    # each event once.
    post!(writer, "general", "Plates are in")
    assert_push_event(view, "worldline:heard", %{events: heard}, 2_000)
    assert %{trail: "room:general", path: "/classic/1?room=general"} = List.last(heard)
    assert List.last(heard).title == "Plates are in"
  end

  test "the list shows the same events as links, newest first, with Older for the page before",
       %{conn: conn} do
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    for n <- 0..24, do: line!("general", DateTime.add(hour_ago, -n))

    {:ok, view, _html} = live(conn, @path <> "?show=list")

    assert has_element?(view, "#worldline-show-list[aria-current=page]")
    refute has_element?(view, "#worldline-stage")
    assert has_element?(view, ~s(#worldline-events a[href="/classic/1?room=general"]))

    # The fleet's newer actions come first: Key 1 bought, and its projects.
    posts = fn -> view |> element("#worldline-events") |> render() |> titles() |> lines() end
    assert length(posts.()) == 20
    assert hd(posts.()) == "Line at #{DateTime.to_iso8601(hour_ago)}"

    view |> element("#worldline-older") |> render_click()
    assert length(posts.()) == 25
    refute has_element?(view, "#worldline-older")

    view |> element("#worldline-show-picture") |> render_click()
    assert_patch(view, @path)
    assert has_element?(view, "#worldline-stage")
  end

  test "a filter in the address keeps one Key's events in the picture, its pages and the list",
       %{conn: conn} do
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    for n <- 0..104, do: line!("general", DateTime.add(hour_ago, -n))
    epoch!(2, "0x" <> String.duplicate("e", 40))

    {:ok, view, _html} = live(conn, @path <> "?by=1")
    assert_push_event(view, "worldline:page", %{events: newest, older: true})
    assert Enum.frequencies_by(newest, & &1.kind) == %{post: 100, sold: 1}
    assert Enum.all?(newest, &(&1.who == "Key 1"))

    render_hook(view, "worldline_older", %{})
    assert_reply(view, %{events: older, older: false})
    assert Enum.frequencies_by(older, & &1.kind) == %{post: 5}

    assert has_element?(view, ~s(#worldline-filter-by[value="Key 1"]))
    assert has_element?(view, ~s(#worldline-show-list[href="#{@path}?show=list&by=1"]))
    assert has_element?(view, ~s(#worldline-filter-clear[href="#{@path}"]))

    # Key 2 has only been bought; a Key nobody has done anything as says so.
    {:ok, view, _html} = live(conn, @path <> "?show=list&by=2")
    assert view |> element("#worldline-events") |> render() |> titles() == ["Key 2 bought"]

    {:ok, view, _html} = live(conn, @path <> "?show=list&by=9")
    assert view |> element("#worldline-empty") |> render() =~ "Nothing matches this filter yet."
  end

  test "the filter field takes a Key number or an address into the address, and answers anything else beside it",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?show=list")

    view |> form("#worldline-filter", by: "#1") |> render_submit()
    assert_patch(view, @path <> "?show=list&by=1")

    view |> form("#worldline-filter", by: String.upcase(@holder)) |> render_submit()
    assert_patch(view, @path <> "?show=list&by=" <> @holder)
    assert view |> element("#worldline-events") |> render() |> titles() == ["Key 1 bought"]

    view |> form("#worldline-filter", by: "Lamp") |> render_submit()
    refute_patched(view)
    assert has_element?(view, "#worldline-filter-by[aria-invalid=true]")

    assert view |> element("#worldline-filter-by-errors") |> render() =~
             "Enter a Key number or a 0x address."

    # A filter in the address that names nothing reads nothing.
    {:ok, view, _html} = live(conn, @path <> "?by=Lamp")
    assert_push_event(view, "worldline:page", %{events: [], older: false})
    assert has_element?(view, "#worldline-filter-by[aria-invalid=true][value=Lamp]")
    refute has_element?(view, "#worldline-empty")
  end

  defp lines(titles), do: Enum.filter(titles, &String.starts_with?(&1, "Line at"))

  defp titles(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".worldline-event__title")
      |> Enum.map(&LazyHTML.text/1)

  defp post!(writer, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: writer
    )
  end

  # A post written at `at`, as Key 1's holder.
  defp line!(slug, at) do
    room = Rooms.get_room!(@fleet, slug, authorize?: false)
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
          author_wallet: @holder,
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

  defp human(wallet), do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp epoch!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/1"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end
