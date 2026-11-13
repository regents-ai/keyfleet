defmodule KeyfleetWeb.Live.AtlasLiveTest do
  # A fleet's Atlas: its members' picture takes the rows once the page is
  # live, then the counts and things it asks for as it moves, and names the
  # window it rests on in the address; the List reads the same window as
  # links, a page at a time; new work reaches an open page. Anyone else reads
  # nothing.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, Atlas, ChainHelpers, Fleets, Keys, Repo, Rooms}
  alias Keyfleet.Atlas.{Count, Fill}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{AtlasLive, SessionAuthorityHelpers, WorkspacePage}

  @endpoint KeyfleetWeb.Endpoint
  @system %Keyfleet.Actors.System{}
  @fleet "fleet_tech_classic"
  @path "/classic/1/atlas"
  @wallet "0x" <> String.duplicate("a1", 20)
  # The fixtures' log starts at noon on Tuesday 22 September 2026, a minute
  # a change.
  @week "#{@path}?window=week&at=2026-09-22"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "lab", "Lab")

    # Twenty-four items in general and three in the lab, the first one
    # patched twice, all counted from the copied log.
    general = for n <- 1..24, do: Workspace.create(@fleet, "task", %{"title" => "Task #{n}"})
    for n <- 1..3, do: Workspace.create(@fleet, "goal", %{"title" => "Goal #{n}"}, project: "lab")
    busiest = hd(general)
    Workspace.edit(@fleet, busiest, %{"title" => "Busiest"}, by: 18)
    Workspace.edit(@fleet, busiest, %{"title" => "Busiest"}, by: 19)
    fill!()

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: @system
    )

    %{busiest: busiest, member: signed_in("did:privy:atlas-member", @wallet)}
  end

  test "a member's picture takes its rows and strip, then what it asks for as it moves",
       %{busiest: busiest, member: member} do
    {:ok, view, _html} = live(member, @week)

    assert has_element?(view, "#fleet-tab-atlas[aria-current=page]")
    assert has_element?(view, "#atlas-window-week[aria-current=page]")

    assert [["general", "General", 26], ["lab", "Lab", 3]] =
             view
             |> element("#atlas-heat")
             |> render()
             |> attribute("data-rows")
             |> Jason.decode!()

    # The strip holds the window's most active, the busiest first.
    assert has_element?(view, "#atlas-active-things > li:first-child#atlas-active-#{id(busiest)}")

    from = DateTime.to_unix(~U[2026-09-21 00:00:00Z])

    render_hook(view, "atlas_cells", %{"span" => "day", "from" => from, "to" => from + 7 * 86_400})

    assert_reply(view, %{
      cells: [
        [at, "general", 26, 24, 3],
        [at, "lab", 3, 3, 1]
      ]
    })

    assert at == DateTime.to_unix(~U[2026-09-22 00:00:00Z])

    render_hook(view, "atlas_cards", %{"at" => DateTime.to_unix(~U[2026-09-22 12:00:00Z])})
    assert_reply(view, %{things: [newest | _] = things})
    assert length(things) == 27
    assert %{what: "Task", who: "Key 19", title: "Busiest", live: true} = newest
    assert newest.path == WorkspacePage.item_path(@fleet, busiest)

    # The view came to rest on a day: the address names it in place.
    render_hook(view, "atlas_window", %{
      "span" => "day",
      "at" => DateTime.to_unix(~U[2026-09-22 15:00:00Z])
    })

    assert_patch(view, "#{@path}?window=day&at=2026-09-22")
    assert has_element?(view, "#atlas-window-day[aria-current=page]")
  end

  test "the List reads the window's totals, projects, most active and latest, a page at a time",
       %{busiest: busiest, member: member} do
    {:ok, view, _html} = live(member, @week <> "&show=list")

    assert view |> element("#atlas-totals") |> render() =~ "29"
    assert has_element?(view, "#atlas-project-general")
    assert has_element?(view, "#atlas-project-lab")

    assert has_element?(
             view,
             ~s(#atlas-most li:first-child a[href="#{WorkspacePage.item_path(@fleet, busiest)}"])
           )

    assert latest(view) |> length() == 20
    view |> element("#atlas-older") |> render_click()
    assert latest(view) |> length() == 27
    refute has_element?(view, "#atlas-older")

    # One kind, and a window with nothing in it.
    {:ok, view, _html} = live(member, @week <> "&show=list&kind=notebooks")
    assert has_element?(view, "#atlas-kind-notebooks[aria-current=page]")
    assert has_element?(view, "#atlas-empty")
    assert latest(view) == []
  end

  test "new work reaches an open page a moment after it is counted", %{member: member} do
    {:ok, list, _html} = live(member, @week <> "&show=list")
    {:ok, picture, _html} = live(member, @week)

    :ok =
      Count.count(@fleet, [
        %{thing: "nb-1", kind: "notebook", project: "lab", at: ~U[2026-09-23 09:00:00Z], key: 1}
      ])

    Atlas.changed(@fleet)

    assert_push_event(picture, "atlas:changed", %{}, 2_000)
    assert eventually(fn -> list |> element("#atlas-totals") |> render() =~ "30" end)
  end

  test "anyone but a member reads nothing" do
    stranger = signed_in("did:privy:atlas-stranger", "0x" <> String.duplicate("e5", 20))

    for conn <- [SessionAuthorityHelpers.build_conn(), stranger] do
      {:ok, view, _html} = live(conn, @week)
      assert has_element?(view, "#atlas-members-only")
      refute has_element?(view, "#atlas-heat")
    end
  end

  defp latest(view) do
    view
    |> element("#atlas-page")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#atlas-latest > li")
    |> Enum.to_list()
  end

  defp attribute(html, name),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> hd()

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end

  defp fill! do
    case Fill.batch(@fleet) do
      {:ok, :counted} -> fill!()
      {:ok, :caught_up} -> :ok
    end
  end

  defp id(thing), do: AtlasLive.dom_id(%{id: thing})

  defp signed_in(did, wallet) do
    account = Accounts.register_verified!(did, wallet, [wallet], actor: @system)

    SessionAuthorityHelpers.build_conn()
    |> SessionAuthorityHelpers.init_test_session(%{human_account_id: account.id})
  end
end
