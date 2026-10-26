defmodule Keyfleet.WorkspaceFixtures do
  @moduledoc """
  Writes a fleet's workspace read tables as the projector leaves them after
  copying a log, through the read tables' System-only record actions.

  Each call appends one change to a made-up log: the event the graph would
  write, the command record it leaves beside it, and the object and link rows
  the change leaves, all committed with the cursor moved past them. Level scopes, attention notices and events of
  any type can be written this way before the graph itself writes them.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Graph

  @system %System{}
  @tables [Graph.Cursor, Graph.Event, Graph.Object, Graph.Relation]
  @contract "0x" <> String.duplicate("b2", 20)
  @wallet "0x" <> String.duplicate("a1", 20)
  @start ~U[2026-09-22 12:00:00Z]

  # Every field the work pack gives a type, at its default, as the graph
  # stores a new object.
  @defaults %{
    "goal" => %{
      "status" => "open",
      "success_criteria" => [],
      "open_questions" => [],
      "discussion" => []
    },
    "task" => %{
      "deliverable" => nil,
      "acceptance_criteria" => [],
      "assignee_key" => nil,
      "reviewer_key" => nil,
      "progress" => "todo",
      "next_step" => nil,
      "commit_ref" => nil,
      "notebook_ref" => nil,
      "result_ref" => nil,
      "discussion" => []
    },
    "finding" => %{"confidence" => "low", "uncertainty" => nil, "discussion" => []},
    "evidence" => %{
      "digest" => nil,
      "excerpt" => nil,
      "how_obtained" => nil,
      "discussion" => []
    },
    "service" => %{
      "payment_asset" => nil,
      "price_proposal" => nil,
      "implementation_refs" => [],
      "discussion" => []
    },
    "note" => %{"discussion" => []},
    "dead_end" => %{"discussion" => []}
  }

  @doc "Starts a project in the fleet beside `general`, as a member's start leaves it."
  def start_project(fleet_id, name, title) do
    Keyfleet.Projects.Project
    |> Ash.Changeset.for_create(:create, %{fleet_id: fleet_id, name: name, title: title},
      actor: @system
    )
    |> Ash.create!()
  end

  @doc "Starts the fleet's copy of a log; the fleet then reads as an empty workspace."
  def open_log(fleet_id, run_id \\ "log_fixture"),
    do: Graph.start_cursor!(%{fleet_id: fleet_id, run_id: run_id}, actor: @system)

  @doc """
  Adds an object and answers its id, `<type>#<place in the log>` unless `:id`
  is given. Options: `:by` (key number, 17) and `:project` (`general`).
  """
  def create(fleet_id, type, data, opts \\ []) do
    sys = %{
      "project" => Keyword.get(opts, :project, "general"),
      "created_by" => member(opts),
      "archived" => false
    }

    add(fleet_id, type, data, sys, principal(opts), opts)
  end

  @doc """
  Adds the workspace's `number`th starting goal, as the graph does when it
  opens the workspace, and answers its id. Options: `:id`.
  """
  def starting_goal(fleet_id, number, data, opts \\ []) do
    sys = %{
      "project" => "general",
      "created_by" => nil,
      "starting" => number,
      "archived" => false
    }

    add(fleet_id, "goal", data, sys, "keyfleet:starting_goals", opts)
  end

  defp add(fleet_id, type, data, sys, actor, opts) do
    data = Map.merge(Map.fetch!(@defaults, type), data)

    append(fleet_id, fn seq ->
      id = Keyword.get(opts, :id, "#{type}##{seq}")

      object = %{"id" => id, "type" => type, "data" => Map.put(data, "sys", sys), "version" => 1}

      Graph.project_objects!(
        [
          %{
            fleet_id: fleet_id,
            id: id,
            type: type,
            project: sys["project"],
            data: data,
            sys: sys,
            version: 1,
            changed_seq: seq,
            changed_at: timestamp(seq)
          }
        ],
        actor: @system
      )

      {id, "object.created", actor, %{"object" => object, "id" => id}}
    end)
  end

  @doc "Changes fields of an object, as a member's patch does."
  def edit(fleet_id, id, set, opts \\ []) do
    append(fleet_id, fn seq ->
      [object] = Graph.read_objects!(fleet_id, [id], actor: @system)
      data = Map.merge(object.data, set)
      project(fleet_id, seq, object, data, object.sys)
      {id, "patch.applied", principal(opts), patch_payload(seq, object, object.data, set)}
    end)
  end

  @doc "Archives an object, as a member's archive does."
  def archive(fleet_id, id, opts \\ []) do
    append(fleet_id, fn seq ->
      [object] = Graph.read_objects!(fleet_id, [id], actor: @system)
      sys = Map.put(object.sys, "archived", true)
      project(fleet_id, seq, object, object.data, sys)
      payload = patch_payload(seq, object, %{"sys" => object.sys}, %{"sys" => sys})
      {id, "patch.applied", principal(opts), payload}
    end)
  end

  @doc "Joins a goal as a member does: the key `:by` with the fixtures' agent wallet."
  def join(fleet_id, id, opts \\ []) do
    append(fleet_id, fn seq ->
      [object] = Graph.read_objects!(fleet_id, [id], actor: @system)
      sys = Map.put(object.sys, "joined", Map.get(object.sys, "joined", []) ++ [member(opts)])
      project(fleet_id, seq, object, object.data, sys)
      payload = patch_payload(seq, object, %{"sys" => object.sys}, %{"sys" => sys})
      {id, "patch.applied", principal(opts), payload}
    end)
  end

  @doc """
  Submits a task for review as a member's submit does: the task is done and
  the key `:by`'s, with `result_ref` as its result.
  """
  def submit(fleet_id, id, result_ref, opts \\ []) do
    append(fleet_id, fn seq ->
      [object] = Graph.read_objects!(fleet_id, [id], actor: @system)
      submitted = Map.merge(member(opts), %{"version" => object.version + 1, "evidence" => []})

      set =
        %{"progress" => "done", "assignee_key" => by(opts), "result_ref" => result_ref}
        |> Enum.reject(fn {field, value} -> object.data[field] == value end)
        |> Map.new()

      data = Map.merge(object.data, set)
      sys = Map.put(object.sys, "submitted", submitted)
      project(fleet_id, seq, object, data, sys)

      payload =
        patch_payload(
          seq,
          object,
          Map.put(object.data, "sys", object.sys),
          Map.put(set, "sys", sys)
        )

      {id, "patch.applied", principal(opts), payload}
    end)
  end

  @doc """
  Reviews a submitted task's current version as a member's review does,
  "accept" or "dispute", and answers the review's id. The review is added,
  then linked to the task. Options: `:by`, `:rationale` and `:reproduction`
  ("passed" or "failed").
  """
  def review(fleet_id, task, decision, opts \\ []) do
    [object] = Graph.read_objects!(fleet_id, [task], actor: @system)

    receipt =
      Map.reject(
        %{
          "task" => task,
          "task_version" => object.version,
          "submitted_by" => Map.drop(object.sys["submitted"], ["version", "evidence"]),
          "evidence" => [],
          "commit_ref" => object.data["commit_ref"]
        },
        fn {_field, value} -> is_nil(value) end
      )

    data = %{
      "decision" => decision,
      "rationale" => Keyword.get(opts, :rationale, "Checked the result."),
      "conflicts_of_interest" => "none",
      "reproduction" => opts[:reproduction]
    }

    id =
      append(fleet_id, fn seq ->
        id = "review##{seq}"

        sys = %{
          "project" => Keyword.get(opts, :project, "general"),
          "created_by" => member(opts),
          "archived" => false,
          "review" => receipt
        }

        Graph.project_objects!(
          [
            %{
              fleet_id: fleet_id,
              id: id,
              type: "review",
              project: sys["project"],
              data: data,
              sys: sys,
              version: 1,
              changed_seq: seq,
              changed_at: timestamp(seq)
            }
          ],
          actor: @system
        )

        object = %{
          "id" => id,
          "type" => "review",
          "data" => Map.put(data, "sys", sys),
          "version" => 1
        }

        {id, "object.created", principal(opts), %{"object" => object, "id" => id}}
      end)

    link(fleet_id, id, task, "reviews", opts)
    id
  end

  @doc "Links two objects and answers the link's id."
  def link(fleet_id, source, target, type, opts \\ []) do
    append(fleet_id, fn seq ->
      id = "rel_#{seq}"

      relation = %{
        "id" => id,
        "source" => source,
        "target" => target,
        "type" => type,
        "data" => %{}
      }

      Graph.project_relations!(
        [
          %{
            fleet_id: fleet_id,
            id: id,
            type: type,
            source: source,
            target: target,
            data: %{},
            created_seq: seq
          }
        ],
        actor: @system
      )

      payload = %{"relation" => relation, "id" => id, "source" => source, "target" => target}
      {id, "relation.created", principal(opts), payload}
    end)
  end

  @doc "Removes a link."
  def unlink(fleet_id, relation_id, opts \\ []) do
    append(fleet_id, fn _seq ->
      Graph.Relation
      |> Ash.Query.for_read(:with_ids, %{fleet_id: fleet_id, ids: [relation_id]}, actor: @system)
      |> Graph.remove_relations!(actor: @system)

      {relation_id, "relation.removed", principal(opts), %{"id" => relation_id}}
    end)
  end

  @doc "Records an attention notice about an object, as the fleet's reactions do."
  def attention(fleet_id, kind, object_id) do
    event(fleet_id, "keyfleet.attention", %{
      "kind" => kind,
      "object_id" => object_id,
      "cause" => %{"event_id" => "evt_cause"},
      "dedupe_key" => "#{kind}:#{object_id}"
    })
  end

  @doc "Records an event of any type that changes no rows, and answers its place in the log."
  def event(fleet_id, type, payload, actor \\ "keyfleet:reactions") do
    append(fleet_id, fn seq -> {seq, type, actor, payload} end)
  end

  # Runs `change` with the next place in the log. It writes the rows its
  # change leaves and answers `{result, type, actor, payload}`; the event and
  # the command record that follows it are recorded, and the cursor moves
  # past both, in one transaction. Answers `result`.
  defp append(fleet_id, change) do
    {:ok, result} =
      Ash.transact(@tables, fn ->
        cursor = Graph.get_cursor!(fleet_id, actor: @system)
        seq = cursor.applied_seq + 1
        {result, type, actor, payload} = change.(seq)

        Graph.record_events!(
          [
            row(fleet_id, seq, type, actor, payload),
            row(fleet_id, seq + 1, "keyfleet.command", "keyfleet:gateway", %{
              "principal" => actor,
              "op" => type,
              "result" => %{},
              "events" => ["evt_#{seq}"]
            })
          ],
          actor: @system
        )

        Graph.advance_cursor!(cursor, %{applied_seq: seq + 1}, actor: @system)
        result
      end)

    result
  end

  defp row(fleet_id, seq, type, actor, payload) do
    %{
      fleet_id: fleet_id,
      seq: seq,
      event_id: "evt_#{seq}",
      type: type,
      actor: actor,
      timestamp: timestamp(seq),
      payload: payload
    }
  end

  defp timestamp(seq), do: @start |> DateTime.add(seq, :minute) |> DateTime.to_iso8601()

  defp project(fleet_id, seq, object, data, sys) do
    Graph.project_objects!(
      [
        %{
          fleet_id: fleet_id,
          id: object.id,
          type: object.type,
          project: object.project,
          data: data,
          sys: sys,
          version: object.version + 1,
          changed_seq: seq,
          changed_at: timestamp(seq)
        }
      ],
      actor: @system
    )
  end

  defp patch_payload(seq, object, old, set) do
    diff = Map.new(set, fn {field, new} -> {field, %{"old" => old[field], "new" => new}} end)

    %{
      "patch" => %{
        "id" => "patch_#{seq}",
        "target" => object.id,
        "op" => "update",
        "value" => set,
        "expected_version" => object.version
      },
      "target" => object.id,
      "diff" => diff
    }
  end

  defp by(opts), do: Keyword.get(opts, :by, 17)

  defp member(opts) do
    %{
      "key" => %{"chain_id" => 1, "contract" => @contract, "token_id" => by(opts)},
      "ownership_epoch" => 3,
      "kind" => "agent",
      "wallet" => @wallet
    }
  end

  defp principal(opts), do: "member:8453:#{@contract}:#{by(opts)}@3/agent:#{@wallet}"
end
