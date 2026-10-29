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

    assert Graph.shown(@fleet) == [
             %{title: "General", goals: ["Sell the first audit"]},
             %{title: "Append-only scratchpad", goals: []},
             %{title: "Keyfleet Syndicate #1 Collaborative Understanding", goals: []}
           ]
  end

  test "each project lists its own goals, newest first, and a project with none lists none" do
    Workspace.start_project(@fleet, "lab", "Lab")
    Workspace.start_project(@fleet, "outreach", "Outreach", by: 21)
    goal("Map the first paid service")
    goal("Try the new model", project: "lab")
    goal("Measure the speed-up", project: "lab")

    assert Graph.shown(@fleet) == [
             %{title: "General", goals: ["Map the first paid service"]},
             %{title: "Append-only scratchpad", goals: []},
             %{title: "Keyfleet Syndicate #1 Collaborative Understanding", goals: []},
             %{title: "Lab", goals: ["Measure the speed-up", "Try the new model"]},
             %{title: "Outreach", goals: []}
           ]
  end

  # A visitor reads a project's work only once the Key holding it shows it.
  test "a project's page lists its work only once its Key shows it to everyone" do
    project = Workspace.start_project(@fleet, "lab", "Lab")
    goal("Try the new model", project: "lab")
    Workspace.create(@fleet, "task", %{"title" => "Draft the price"}, project: "lab")

    hidden = KeyfleetWeb.ProjectPage.read(@fleet, "lab")
    assert hidden.goals == ["Try the new model"]
    assert hidden.parts == nil
    assert Ash.read!(work("lab")) == []

    project
    |> Ash.Changeset.for_update(:shown, %{shown_to_everyone: true, key: 20},
      actor: %Keyfleet.Actors.System{}
    )
    |> Ash.update!()

    shown = KeyfleetWeb.ProjectPage.read(@fleet, "lab")
    assert shown.goals == nil
    assert [%{title: "Draft the price"}] = shown.parts.work.items
    assert [%{title: "Try the new model"}] = shown.parts.goals.items
  end

  # Costly failure: a visitor shown a task under the wrong goal, or a task
  # of a project its Key never showed, or more of a task than its title and
  # status.
  test "a shown project's goals list the tasks that deliver on them, by title and status alone" do
    project = Workspace.start_project(@fleet, "lab", "Lab")
    model = goal("Try the new model", project: "lab")
    other = goal("Measure the speed-up", project: "lab")

    task =
      Workspace.create(@fleet, "task", %{"title" => "Draft the price", "progress" => "doing"},
        project: "lab"
      )

    Workspace.link(@fleet, task, model, "implements")
    old = Workspace.create(@fleet, "task", %{"title" => "Old try"}, project: "lab")
    Workspace.link(@fleet, old, model, "implements")
    Workspace.archive(@fleet, old)
    aside = Workspace.create(@fleet, "task", %{"title" => "Aside"}, project: "lab")
    Workspace.link(@fleet, aside, other, "references")

    assert Graph.shown_goal_tasks!(@fleet, "lab", model) == []

    project
    |> Ash.Changeset.for_update(:shown, %{shown_to_everyone: true, key: 20},
      actor: %Keyfleet.Actors.System{}
    )
    |> Ash.update!()

    goals = KeyfleetWeb.ProjectPage.read(@fleet, "lab").parts.goals.items
    by_id = Map.new(goals, &{&1.id, &1.tasks})

    assert [%{id: ^task, title: "Draft the price", standing: "In progress"} = shown] =
             by_id[model]

    assert Map.keys(shown) |> Enum.sort() == [:id, :path, :standing, :title]
    assert by_id[other] == []
  end

  defp work(project),
    do:
      Ash.Query.for_read(Keyfleet.Graph.Object, :shown, %{
        fleet_id: @fleet,
        project: project,
        part: :work
      })

  defp goal(title, opts \\ []),
    do: Workspace.create(@fleet, "goal", %{"title" => title, "outcome" => "O"}, opts)
end
