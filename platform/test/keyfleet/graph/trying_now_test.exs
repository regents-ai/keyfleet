defmodule Keyfleet.Graph.TryingNowTest do
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

  test "an achieved, dropped or archived goal isn't one the fleet is trying" do
    open = goal("Sell the first audit")
    Workspace.edit(@fleet, goal("Ship the site"), %{"status" => "achieved"})
    Workspace.edit(@fleet, goal("Run a raffle"), %{"status" => "dropped"})
    Workspace.archive(@fleet, goal("Old plan"))

    assert [%{goal: %{id: ^open}}] = Graph.trying_now(@fleet).goals
  end

  test "a task linked to a goal as implementing it is listed under the goal with its key" do
    goal = goal("Sell the first audit")
    other = goal("Find a second customer")

    doing = task("Draft the price", %{"progress" => "doing", "assignee_key" => 12})
    todo = task("Write the offer")
    Workspace.link(@fleet, doing, goal, "implements")
    Workspace.link(@fleet, todo, goal, "implements")

    # Linked some other way, archived, or a service rather than a task.
    Workspace.link(@fleet, task("Unrelated"), goal, "depends_on")
    Workspace.archive(@fleet, link_task(goal, "Abandoned"))
    service = Workspace.create(@fleet, "service", service_data())
    Workspace.link(@fleet, service, goal, "implements")

    %{goals: goals} = Graph.trying_now(@fleet)

    assert [%{goal: %{id: ^other}, tasks: []}, %{goal: %{id: ^goal}, tasks: tasks}] = goals

    assert [
             %{task: %{id: ^todo}, assignee_key: nil, progress: "todo"},
             %{task: %{id: ^doing, title: "Draft the price"}, assignee_key: 12, progress: "doing"}
           ] = tasks
  end

  test "each goal lists its five newest tasks, however many another goal has" do
    busy = goal("Busy")
    quiet = goal("Quiet")
    busy_tasks = for n <- 1..7, do: link_task(busy, "Busy #{n}")
    quiet_task = link_task(quiet, "Quiet one")

    by_goal = Map.new(Graph.trying_now(@fleet).goals, &{&1.goal.id, ids(&1.tasks)})

    assert by_goal[busy] == busy_tasks |> Enum.reverse() |> Enum.take(5)
    assert by_goal[quiet] == [quiet_task]
  end

  test "who's on what lists only tasks a key has taken and is working on" do
    taken = task("Draft the price", %{"progress" => "doing", "assignee_key" => 12})
    task("Marked doing, nobody on it", %{"progress" => "doing"})
    task("Claimed, not started", %{"assignee_key" => 9})
    task("Finished", %{"progress" => "done", "assignee_key" => 3})

    assert [%{task: %{id: ^taken}, assignee_key: 12}] = Graph.trying_now(@fleet).taken
  end

  test "the three newest findings are listed, newest first" do
    [_oldest | newest] =
      for n <- 1..4 do
        Workspace.create(@fleet, "finding", %{"title" => "Finding #{n}", "statement" => "S#{n}"})
      end

    assert ids(Graph.trying_now(@fleet).findings) == Enum.reverse(newest)
  end

  test "a contradicts link is an open problem until it is unlinked" do
    target = goal("Sell the first audit")
    finding = Workspace.create(@fleet, "finding", %{"title" => "No buyers", "statement" => "S"})
    link = Workspace.link(@fleet, finding, target, "contradicts")
    Workspace.link(@fleet, finding, target, "supports")

    assert [%{relation: %{id: ^link}, source: %{id: ^finding}, target: %{id: ^target}}] =
             Graph.trying_now(@fleet).problems

    Workspace.unlink(@fleet, link)

    assert Graph.trying_now(@fleet).problems == []
  end

  test "a problem raised by or about an archived object isn't open" do
    target = goal("Sell the first audit")
    finding = Workspace.create(@fleet, "finding", %{"title" => "No buyers", "statement" => "S"})
    Workspace.link(@fleet, finding, target, "contradicts")

    Workspace.archive(@fleet, finding)

    assert Graph.trying_now(@fleet).problems == []
  end

  test "the open question is the newest open goal's first one" do
    goal("Asked", %{"open_questions" => ["Who pays?", "When?"]})
    assert %{question: "Who pays?"} = Graph.trying_now(@fleet)

    newest = goal("Quiet goal")
    assert %{question: nil} = Graph.trying_now(@fleet)
    assert Graph.open_question(@fleet) == nil

    Workspace.edit(@fleet, newest, %{"open_questions" => ["Which chain?"]})

    assert %{goal: %{id: ^newest}, question: "Which chain?"} = Graph.open_question(@fleet)
    assert %{question: "Which chain?"} = Graph.trying_now(@fleet)
  end

  test "another fleet's goals, tasks and links stay out" do
    goal = goal("Sell the first audit")
    Workspace.open_log(@other_fleet)

    other_task =
      Workspace.create(@other_fleet, "task", %{"title" => "Theirs", "progress" => "doing"},
        id: "task#elsewhere"
      )

    # The same ids in the other fleet, linked there.
    Workspace.create(@other_fleet, "goal", %{"title" => "Twin", "outcome" => "O"}, id: goal)
    Workspace.link(@other_fleet, other_task, goal, "implements")

    assert [%{goal: %{id: ^goal}, tasks: []}] = Graph.trying_now(@fleet).goals
  end

  defp goal(title, data \\ %{}),
    do: Workspace.create(@fleet, "goal", Map.merge(%{"title" => title, "outcome" => "O"}, data))

  defp task(title, data \\ %{}),
    do: Workspace.create(@fleet, "task", Map.put(data, "title", title))

  defp link_task(goal, title) do
    task = task(title)
    Workspace.link(@fleet, task, goal, "implements")
    task
  end

  defp service_data,
    do: %{"title" => "Audit", "customer" => "C", "problem" => "P", "deliverable" => "D"}

  defp ids(items), do: Enum.map(items, &Map.get(&1, :task, &1).id)
end
