defmodule Keyfleet.Graph.ShownTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Repo
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"

  setup do
    # The read takes a repeatable-read snapshot, which Postgres allows inside
    # the sandbox only when its transaction is at that level already.
    owner = Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    Workspace.open_log(@fleet)
    :ok
  end

  test "an achieved, dropped or archived goal, a task or another fleet's goal isn't shown" do
    goal("Sell the first audit")
    Workspace.edit(@fleet, goal("Ship the site"), %{"status" => "achieved"})
    Workspace.edit(@fleet, goal("Run a raffle"), %{"status" => "dropped"})
    Workspace.archive(@fleet, goal("Old plan"))
    Workspace.create(@fleet, "task", %{"title" => "Draft the price"})

    Workspace.open_log(@other_fleet)
    Workspace.create(@other_fleet, "goal", %{"title" => "Theirs", "outcome" => "O"})

    assert Graph.shown(@fleet) == [%{title: "General", goals: ["Sell the first audit"]}]
  end

  test "each project lists its own goals, newest first, and a project with none lists none" do
    Workspace.start_project(@fleet, "lab", "Lab")
    Workspace.start_project(@fleet, "outreach", "Outreach", by: 21)
    goal("Map the first paid service")
    goal("Try the new model", project: "lab")
    goal("Measure the speed-up", project: "lab")

    assert Graph.shown(@fleet) == [
             %{title: "General", goals: ["Map the first paid service"]},
             %{title: "Lab", goals: ["Measure the speed-up", "Try the new model"]},
             %{title: "Outreach", goals: []}
           ]
  end

  defp goal(title, opts \\ []),
    do: Workspace.create(@fleet, "goal", %{"title" => title, "outcome" => "O"}, opts)
end
