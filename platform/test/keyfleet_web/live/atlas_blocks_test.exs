defmodule KeyfleetWeb.Live.AtlasBlocksTest do
  # The Atlas as blocks (`?view=blocks`): a member's blocks take the projects,
  # the kinds and the window, then the window's counts by project and kind and
  # a kind's things as they ask for them; moving through time keeps the
  # blocks. Anyone else reads nothing.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, ChainHelpers, Fleets, Graph, Keys, Repo, Rooms}
  alias Keyfleet.Atlas.Fill
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{SessionAuthorityHelpers, WorkspacePage}

  @endpoint KeyfleetWeb.Endpoint
  @system %Keyfleet.Actors.System{}
  @fleet "fleet_tech_classic"
  @path "/classic/1/atlas"
  @wallet "0x" <> String.duplicate("b2", 20)
  # The fixtures' log starts at noon on Tuesday 22 September 2026.
  @blocks "#{@path}?view=blocks&window=week&at=2026-09-22"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "lab", "Lab")

    # Four tasks in general by Key 17, the first patched by Keys 18 and 19,
    # and three goals in the lab by Key 17.
    general = for n <- 1..4, do: Workspace.create(@fleet, "task", %{"title" => "Task #{n}"})
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
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("b", 64),
        log_index: 0
      },
      actor: @system
    )

    %{busiest: busiest, member: signed_in("did:privy:atlas-blocks-member", @wallet)}
  end

  test "a member's blocks take the projects, kinds and window, then counts by kind and a kind's things",
       %{busiest: busiest, member: member} do
    {:ok, view, _html} = live(member, @blocks)

    assert has_element?(view, "#atlas-show-blocks[aria-current=page]")
    refute has_element?(view, "#atlas-show-heat[aria-current=page]")
    refute has_element?(view, "#atlas-heat")

    blocks = view |> element("#atlas-blocks") |> render()
    assert Enum.sort(data(blocks, "data-rows")) == [["general", "General"], ["lab", "Lab"]]
    assert Enum.map(data(blocks, "data-kinds"), &hd/1) == WorkspacePage.types() ++ ["notebook"]

    from = DateTime.to_unix(~U[2026-09-21 00:00:00Z])
    assert attribute(blocks, "data-from") == Integer.to_string(from)
    assert attribute(blocks, "data-to") == Integer.to_string(from + 7 * 86_400)
    assert attribute(blocks, "data-window") == "week"
    assert attribute(blocks, "data-kind") == "all"

    # The strip holds the window's most active and opens the blocks down to it.
    assert view
           |> element("#atlas-active-things > li:first-child button")
           |> render() =~ "atlas:focus"

    # Each kind of each project: its changes, things and Keys, the day it was
    # last worked on, and not today, as the window is past.
    day = DateTime.to_unix(~U[2026-09-22 00:00:00Z])
    render_hook(view, "atlas_blocks_fleet", %{})
    assert_reply(view, %{now: now, bucket: :day, kinds: kinds, keys: keys})
    assert_in_delta now, DateTime.to_unix(DateTime.utc_now()), 60

    assert Enum.sort(kinds) == [
             ["general", "task", 6, 4, 3, day, false],
             ["lab", "goal", 3, 3, 1, day, false]
           ]

    assert Enum.sort(keys) == [["general", 3], ["lab", 1]]

    # A kind's things, the most active first, and nothing after the last.
    render_hook(view, "atlas_blocks_things", %{
      "project" => "general",
      "kind" => "task",
      "after" => nil
    })

    assert_reply(view, %{things: [first | _] = things, after: nil})
    assert length(things) == 4
    assert %{id: ^busiest, title: "Busiest", changes: 3, actors: 3, live: true} = first
    assert first.path == WorkspacePage.item_path(@fleet, busiest)
    [object] = Graph.read_objects!(@fleet, [busiest], actor: @system)
    {:ok, changed_at, 0} = DateTime.from_iso8601(object.changed_at)
    assert first.at == DateTime.to_unix(changed_at, :millisecond)

    render_hook(view, "atlas_blocks_things", %{
      "project" => "lab",
      "kind" => "task",
      "after" => nil
    })

    assert_reply(view, %{things: [], after: nil})
  end

  test "the kind chosen reaches the blocks and their counts", %{member: member} do
    {:ok, view, _html} = live(member, @blocks <> "&kind=graph")
    assert has_element?(view, "#atlas-blocks[data-kind=graph]")

    render_hook(view, "atlas_blocks_fleet", %{})
    assert_reply(view, %{kinds: kinds})
    assert Enum.map(Enum.sort(kinds), &Enum.take(&1, 2)) == [["general", "task"], ["lab", "goal"]]
  end

  test "moving through time and between kinds keeps the blocks", %{member: member} do
    {:ok, view, _html} = live(member, @blocks)

    for link <-
          ~w(#atlas-blocks-earlier #atlas-blocks-later #atlas-window-day #atlas-kind-notebooks #atlas-show-list) do
      assert view |> element(link) |> render() |> attribute("href") =~ "view=blocks"
    end

    view |> element("#atlas-blocks-earlier") |> render_click()
    assert_patch(view, "#{@path}?view=blocks&window=week&at=2026-09-20")

    assert has_element?(
             view,
             "#atlas-blocks[data-to='#{DateTime.to_unix(~U[2026-09-21 00:00:00Z])}']"
           )

    # A window with nothing in it of the kind chosen.
    {:ok, view, _html} = live(member, @blocks <> "&kind=notebooks")
    assert has_element?(view, "#atlas-empty")
    refute has_element?(view, "#atlas-blocks")
  end

  test "anyone but a member reads nothing" do
    stranger = signed_in("did:privy:atlas-blocks-stranger", "0x" <> String.duplicate("e6", 20))

    for conn <- [SessionAuthorityHelpers.build_conn(), stranger] do
      {:ok, view, _html} = live(conn, @blocks)
      assert has_element?(view, "#atlas-members-only")
      refute has_element?(view, "#atlas-blocks")
    end
  end

  defp data(html, name), do: html |> attribute(name) |> Jason.decode!()

  defp attribute(html, name),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> hd()

  defp fill! do
    case Fill.batch(@fleet) do
      {:ok, :counted} -> fill!()
      {:ok, :caught_up} -> :ok
    end
  end

  defp signed_in(did, wallet) do
    account = Accounts.register_verified!(did, wallet, [wallet], actor: @system)

    SessionAuthorityHelpers.build_conn()
    |> SessionAuthorityHelpers.init_test_session(%{human_account_id: account.id})
  end
end
