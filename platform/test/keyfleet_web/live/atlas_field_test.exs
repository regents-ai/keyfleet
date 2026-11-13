defmodule KeyfleetWeb.Live.AtlasFieldTest do
  # The Atlas as a field (`?view=field`): a member's field takes the rows, the
  # kinds and the window once the page is live, then each project's counts by
  # kind and an hour's things as it asks for them; moving through time keeps
  # the field. Anyone else reads nothing.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, ChainHelpers, Fleets, Keys, Repo, Rooms}
  alias Keyfleet.Atlas.Fill
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{SessionAuthorityHelpers, WorkspacePage}

  @endpoint KeyfleetWeb.Endpoint
  @system %Keyfleet.Actors.System{}
  @fleet "fleet_tech_classic"
  @path "/classic/1/atlas"
  @wallet "0x" <> String.duplicate("b2", 20)
  # The fixtures' log starts at noon on Tuesday 22 September 2026.
  @field "#{@path}?view=field&window=week&at=2026-09-22"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "lab", "Lab")

    # Four tasks in general, the first patched twice, and three goals in the lab.
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

    %{busiest: busiest, member: signed_in("did:privy:atlas-field-member", @wallet)}
  end

  test "a member's field takes its rows, kinds and window, then counts by kind and an hour's things",
       %{busiest: busiest, member: member} do
    {:ok, view, _html} = live(member, @field)

    assert has_element?(view, "#atlas-show-field[aria-current=page]")
    refute has_element?(view, "#atlas-show-heat[aria-current=page]")
    refute has_element?(view, "#atlas-heat")

    field = view |> element("#atlas-field") |> render()
    assert [["general", "General", 6], ["lab", "Lab", 3]] = data(field, "data-rows")
    assert Enum.map(data(field, "data-kinds"), &hd/1) == WorkspacePage.types() ++ ["notebook"]

    from = DateTime.to_unix(~U[2026-09-21 00:00:00Z])
    assert attribute(field, "data-from") == Integer.to_string(from)
    assert attribute(field, "data-to") == Integer.to_string(from + 7 * 86_400)
    assert attribute(field, "data-window") == "week"

    # The strip holds the window's most active, the busiest first, and brings
    # the field to it.
    assert view
           |> element("#atlas-active-things > li:first-child button")
           |> render() =~ "atlas:focus"

    day = DateTime.to_unix(~U[2026-09-22 00:00:00Z])
    week = %{"span" => "day", "from" => from, "to" => from + 7 * 86_400}

    render_hook(view, "atlas_field_cells", Map.put(week, "project", nil))
    assert_reply(view, %{cells: cells})
    assert Enum.sort(cells) == [[day, "general", "task", 6, 4], [day, "lab", "goal", 3, 3]]

    render_hook(view, "atlas_field_cells", Map.put(week, "project", "lab"))
    assert_reply(view, %{cells: [[^day, "lab", "goal", 3, 3]]})

    noon = DateTime.to_unix(~U[2026-09-22 12:00:00Z])
    render_hook(view, "atlas_field_things", %{"project" => "general", "at" => noon})
    assert_reply(view, %{things: [newest | _] = things})
    assert length(things) == 4
    assert Enum.all?(things, &(&1.project == "general" and &1.kind == "task"))
    assert %{who: "Key 19", title: "Busiest", live: true} = newest
    assert newest.path == WorkspacePage.item_path(@fleet, busiest)

    render_hook(view, "atlas_field_things", %{"project" => "lab", "at" => noon + 3_600})
    assert_reply(view, %{things: []})
  end

  test "moving through time and between kinds keeps the field", %{member: member} do
    {:ok, view, _html} = live(member, @field)

    for link <-
          ~w(#atlas-field-earlier #atlas-field-later #atlas-window-day #atlas-kind-notebooks) do
      assert view |> element(link) |> render() |> attribute("href") =~ "view=field"
    end

    view |> element("#atlas-field-earlier") |> render_click()
    assert_patch(view, "#{@path}?view=field&window=week&at=2026-09-20")

    assert has_element?(
             view,
             "#atlas-field[data-to='#{DateTime.to_unix(~U[2026-09-21 00:00:00Z])}']"
           )

    # A window with nothing in it of the kind chosen.
    {:ok, view, _html} = live(member, @field <> "&kind=notebooks")
    assert has_element?(view, "#atlas-empty")
    refute has_element?(view, "#atlas-field")
  end

  test "anyone but a member reads nothing" do
    stranger = signed_in("did:privy:atlas-field-stranger", "0x" <> String.duplicate("e6", 20))

    for conn <- [SessionAuthorityHelpers.build_conn(), stranger] do
      {:ok, view, _html} = live(conn, @field)
      assert has_element?(view, "#atlas-members-only")
      refute has_element?(view, "#atlas-field")
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
