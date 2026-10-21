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

    assert [%{id: ^open, title: "Sell the first audit"}] = Graph.trying_now(@fleet).goals
  end

  # A task given to a Key counts as taken before the Key starts it, so every
  # unfinished task is either taken or not taken yet.
  test "the open work is counted, and finished, archived or another fleet's work isn't" do
    goal("Sell the first audit")
    task("Draft the price", %{"progress" => "doing", "assignee_key" => 12})
    task("Marked doing, nobody on it", %{"progress" => "doing"})
    task("Write the offer")
    task("Claimed, not started", %{"assignee_key" => 9})
    Workspace.submit(@fleet, task("Finished"), "https://example.com/finished", by: 3)
    Workspace.archive(@fleet, task("Abandoned"))

    Workspace.open_log(@other_fleet)
    Workspace.create(@other_fleet, "task", %{"title" => "Theirs"}, id: "task#elsewhere")

    assert Graph.trying_now(@fleet).counts == %{
             goals_open: 1,
             tasks_taken: 2,
             tasks_untaken: 2
           }
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

  defp goal(title, data \\ %{}),
    do: Workspace.create(@fleet, "goal", Map.merge(%{"title" => title, "outcome" => "O"}, data))

  defp task(title, data \\ %{}),
    do: Workspace.create(@fleet, "task", Map.put(data, "title", title))
end
