defmodule KeyfleetWeb.Live.AtlasRiverTest do
  # The Atlas as a river: chosen in the address, it takes the rows once the
  # page is live, then answers what it asks for as it moves (each project's
  # counts with its notebooks' share, one project's kinds of work, and the
  # things it changed in an hour), and keeps itself in the address as the
  # window moves.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.{Accounts, ChainHelpers, Fleets, Keys, Repo, Rooms}
  alias Keyfleet.Atlas.{Count, Fill}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.{SessionAuthorityHelpers, WorkspacePage}

  @endpoint KeyfleetWeb.Endpoint
  @system %Keyfleet.Actors.System{}
  @fleet "fleet_tech_classic"
  @path "/classic/1/atlas"
  @wallet "0x" <> String.duplicate("b2", 20)
  # The fixtures' log starts at noon on Tuesday 22 September 2026, a minute
  # a change; a notebook in the lab is saved an hour later.
  @week "#{@path}?view=river&window=week&at=2026-09-22"
  @day DateTime.to_unix(~U[2026-09-22 00:00:00Z])
  @noon DateTime.to_unix(~U[2026-09-22 12:00:00Z])
  @one "#{@noon + 3600}"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "lab", "Lab")

    general = for n <- 1..24, do: Workspace.create(@fleet, "task", %{"title" => "Task #{n}"})
    for n <- 1..3, do: Workspace.create(@fleet, "goal", %{"title" => "Goal #{n}"}, project: "lab")
    Workspace.edit(@fleet, hd(general), %{"title" => "Busiest"}, by: 18)
    Workspace.edit(@fleet, hd(general), %{"title" => "Busiest"}, by: 19)
    fill!()

    :ok =
      Count.count(@fleet, [
        %{thing: "nb-1", kind: "notebook", project: "lab", at: ~U[2026-09-22 13:05:00Z], key: 1}
      ])

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

    %{busiest: hd(general), member: signed_in("did:privy:river-member", @wallet)}
  end

  test "the river is chosen in the address and draws the fleet's projects, busiest first",
       %{member: member} do
    {:ok, view, _html} = live(member, @week)

    assert has_element?(view, "#atlas-show-river[aria-current=page]")
    refute has_element?(view, "#atlas-show-heat[aria-current=page]")
    refute has_element?(view, "#atlas-heat")

    river = view |> element("#atlas-river") |> render()

    assert [["general", "General", 26], ["lab", "Lab", 4]] =
             river |> attribute("data-rows") |> Jason.decode!()

    assert attribute(river, "data-kind") == "all"
    assert attribute(river, "data-window") == "week"

    # Heat is shown unless another picture is named.
    {:ok, heat, _html} = live(member, "#{@path}?window=week&at=2026-09-22")
    assert has_element?(heat, "#atlas-heat")
    refute has_element?(heat, "#atlas-river")
  end

  test "each project's counts come with its notebooks' share, for every kind of work shown",
       %{member: member} do
    {:ok, view, _html} = live(member, @week)
    week = %{"read" => "cells", "span" => "day", "from" => @day, "to" => @day + 7 * 86_400}

    render_hook(view, "atlas_river", week)
    assert_reply(view, %{cells: cells})

    assert [[@day, "general", 26, 24, 3, 0], [@day, "lab", 4, 4, _keys, 1]] =
             Enum.sort_by(cells, &Enum.at(&1, 1))

    {:ok, notebooks, _html} = live(member, @week <> "&kind=notebooks")

    assert notebooks |> element("#atlas-river") |> render() |> attribute("data-kind") ==
             "notebook"

    render_hook(notebooks, "atlas_river", week)
    assert_reply(notebooks, %{cells: [[@day, "lab", 1, 1, 1, 1]]})

    {:ok, graph, _html} = live(member, @week <> "&kind=graph")
    render_hook(graph, "atlas_river", week)
    assert_reply(graph, %{cells: cells})
    assert Enum.all?(cells, &(List.last(&1) == 0))
    assert cells |> Enum.map(&Enum.at(&1, 2)) |> Enum.sum() == 29
  end

  test "a project's kinds of work come an hour at a time, each with its lane's name",
       %{member: member} do
    {:ok, view, _html} = live(member, @week)
    day = %{"read" => "lanes", "from" => @day, "to" => @day + 86_400}

    render_hook(view, "atlas_river", Map.put(day, "project", "general"))
    assert_reply(view, %{cells: [[@noon, "task", 26, 24, 3]], names: names})
    assert Map.keys(names) == ["task"]

    render_hook(view, "atlas_river", Map.put(day, "project", "lab"))
    assert_reply(view, %{cells: cells, names: names})
    assert [[@noon, "goal", 3, 3, _], [noon_and_one, "notebook", 1, 1, 1]] = Enum.sort(cells)
    assert "#{noon_and_one}" == @one
    assert names |> Map.keys() |> Enum.sort() == ["goal", "notebook"]
  end

  test "a project's things in one hour come newest first, each with its own page",
       %{busiest: busiest, member: member} do
    {:ok, view, _html} = live(member, @week)

    render_hook(view, "atlas_river", %{"read" => "items", "at" => @noon, "project" => "general"})
    assert_reply(view, %{things: [newest | _] = things})
    assert length(things) == 24
    assert Enum.all?(things, &(&1.kind == "task" and &1.live))
    assert %{id: ^busiest, changes: 3} = newest
    assert newest.path == WorkspacePage.item_path(@fleet, busiest)

    render_hook(view, "atlas_river", %{
      "read" => "items",
      "at" => @noon + 3600,
      "project" => "lab"
    })

    assert_reply(view, %{things: [%{id: "nb-1", kind: "notebook", live: false}]})
  end

  test "the window the river rests on is named in the address, the river kept",
       %{member: member} do
    {:ok, view, _html} = live(member, @week)

    render_hook(view, "atlas_window", %{"span" => "day", "at" => @noon})

    assert_patch(view, "#{@path}?view=river&window=day&at=2026-09-22")
    assert has_element?(view, "#atlas-river")
    assert view |> element("#atlas-river") |> render() |> attribute("data-window") == "day"
  end

  test "anyone but a member reads nothing" do
    stranger = signed_in("did:privy:river-stranger", "0x" <> String.duplicate("e6", 20))

    for conn <- [SessionAuthorityHelpers.build_conn(), stranger] do
      {:ok, view, _html} = live(conn, @week)
      assert has_element?(view, "#atlas-members-only")
      refute has_element?(view, "#atlas-river")
    end
  end

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
