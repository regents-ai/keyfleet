defmodule KeyfleetWeb.Live.SearchPageTest do
  # A fleet's search page finds what its reader may read, each line opening
  # the page it is on, and pages on with "Show more".
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Accounts, Actors, ChainHelpers, Dms, Fleets, Keys, PairingHelpers, Rooms}
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fleet_tech_classic"
  @path "/classic/1/search"
  @holder "0x" <> String.duplicate("d", 40)
  @other "0x" <> String.duplicate("e", 40)

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    epoch!(1, @holder)
    epoch!(2, @other)
    %{writer: PairingHelpers.agent_for!(human(@holder))}
  end

  test "a holder finds posts, messages and items, and anyone else the public posts",
       %{conn: conn, writer: writer} do
    post!(writer, "general", "Hull survey started")
    post!(writer, "coding", "Hull plates welded")
    Dms.send_dm!(dm(2, 1, "Hull looks sound"), actor: human(@other))
    task = Workspace.create(@fleet, "task", %{"title" => "Check the hull"})

    {:ok, view, _html} = conn |> signed_in_as(@holder) |> live(@path <> "?q=hull")

    assert has_element?(view, ~s(#search-matches a[href="/classic/1?room=general"]), "Public")
    assert has_element?(view, ~s(#search-matches a[href="/classic/1?room=coding"]), "Coding")
    assert has_element?(view, ~s(#search-matches a[href="/classic/1/keys/1/dms/2"]), "Key 2")

    assert has_element?(
             view,
             ~s(#search-matches a[href="/classic/1/workspace/#{URI.encode_www_form(task)}"]),
             "Check the hull"
           )

    {:ok, view, _html} = live(build_conn(), @path <> "?q=hull")

    assert has_element?(view, "#search-matches li", "Hull survey started")
    assert view |> element("#search-matches") |> render() |> count_lines() == 1
  end

  test "the bar's box opens the search, and Show more adds the next page",
       %{conn: conn, writer: writer} do
    for n <- 1..21, do: post!(writer, "general", "Rotor reading #{n}")

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#search-idle")

    view |> form("#fleet-search", %{q: "rotor"}) |> render_submit()
    assert_patch(view, @path <> "?q=rotor")
    assert view |> element("#search-matches") |> render() |> count_lines() == 20

    view |> element("#search-more") |> render_click()
    assert view |> element("#search-matches") |> render() |> count_lines() == 21
    refute has_element?(view, "#search-more")

    view |> form("#fleet-search", %{q: "nothing here"}) |> render_submit()
    assert has_element?(view, "#search-none")
  end

  test "a q that is not words reads as no search, and the box does nothing off a fleet",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?q[]=hull")
    assert has_element?(view, "#search-idle")

    {:ok, view, _html} = live(build_conn(), "/about")
    render_hook(view, "search", %{"q" => "hull"})
    assert Process.alive?(view.pid)
  end

  defp count_lines(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query("li") |> Enum.count()

  defp post!(writer, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: writer
    )
  end

  defp dm(from, to, body),
    do: %{
      fleet_id: @fleet,
      from_token_id: from,
      to_token_id: to,
      body: body,
      idempotency_key: Ash.UUID.generate()
    }

  defp human(wallet), do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:search-page:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

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
