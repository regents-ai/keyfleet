defmodule KeyfleetWeb.PublicWorkspaceTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Rooms
  alias Keyfleet.SharedReading
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.FleetNow

  @fleet "fibonacci_syndicate"

  # Everything members wrote that is not a project's title or an open goal's
  # title, and the project's own name.
  @private [
    "rd-lab",
    "One paying customer.",
    "Who pays first?",
    "Finding a first customer.",
    "Draft the brief",
    "Call the fund on Tuesday.",
    "Old idea",
    "Standup",
    "Ship it."
  ]

  setup do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    SharedReading.delete(FleetNow.key(@fleet))
    Workspace.open_log(@fleet)
    Workspace.start_project(@fleet, "rd-lab", "Lab")

    Workspace.create(@fleet, "goal", %{
      "title" => "Revenue",
      "outcome" => "One paying customer.",
      "open_questions" => ["Who pays first?"],
      "success_criteria" => ["Finding a first customer."]
    })

    Workspace.create(@fleet, "goal", %{"title" => "Old idea", "status" => "dropped"})
    Workspace.create(@fleet, "goal", %{"title" => "Try the model"}, project: "rd-lab")

    Workspace.create(
      @fleet,
      "task",
      %{"title" => "Draft the brief", "next_step" => "Call the fund on Tuesday."},
      project: "rd-lab"
    )

    Workspace.create(@fleet, "note", %{"title" => "Standup", "body" => "Ship it."})
    FleetNow.read(@fleet)
    :ok
  end

  test "public reads carry project titles and open goals' titles, and nothing else of the workspace",
       %{conn: conn} do
    json = conn |> get("/api/v1/fleets/#{@fleet}") |> json_response(200)

    assert json["projects"] == [
             %{"title" => "General", "goals" => ["Revenue"]},
             %{"title" => "Lab", "goals" => ["Try the model"]}
           ]

    markdown = conn |> get("/fleets/#{@fleet}.md") |> response(200)
    assert markdown =~ "## Projects\n\n- “General”\n  - “Revenue”\n- “Lab”\n  - “Try the model”\n"

    {:ok, hall, _html} = live(conn, Fleets.path(@fleet))
    {:ok, workspace, _html} = live(conn, Fleets.path(@fleet) <> "/workspace")

    for page <- [render(hall), render(workspace)] do
      assert page =~ "Revenue"
      assert page =~ "Try the model"
    end

    for body <- [Jason.encode!(json), markdown, render(hall), render(workspace)],
        written <- @private do
      refute body =~ written
    end
  end
end
