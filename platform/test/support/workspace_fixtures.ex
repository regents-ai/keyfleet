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
      "assignee_key" => nil,
      "progress" => "todo",
      "next_step" => nil,
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

  @doc "Starts the fleet's copy of a log; the fleet then reads as an empty workspace."
  def open_log(fleet_id, run_id \\ "log_fixture"),
    do: Graph.start_cursor!(%{fleet_id: fleet_id, run_id: run_id}, actor: @system)

  @doc """
  Adds an object and answers its id, `<type>#<place in the log>` unless `:id`
  is given. Options: `:by` (key number, 17), `:scope` ("fleet").
  """
  def create(fleet_id, type, data, opts \\ []) do
    data = Map.merge(Map.fetch!(@defaults, type), data)

    append(fleet_id, fn seq ->
      id = Keyword.get(opts, :id, "#{type}##{seq}")

      sys = %{
        "scope" => Keyword.get(opts, :scope, "fleet"),
        "created_by" => %{
          "key" => %{"chain_id" => 1, "contract" => @contract, "token_id" => by(opts)},
          "ownership_epoch" => 3,
          "kind" => "agent",
          "wallet" => @wallet
        },
        "archived" => false
      }

      object = %{"id" => id, "type" => type, "data" => Map.put(data, "sys", sys), "version" => 1}

      Graph.project_objects!(
        [
          %{
            fleet_id: fleet_id,
            id: id,
            type: type,
            data: data,
            sys: sys,
            version: 1,
            changed_seq: seq,
            changed_at: timestamp(seq)
          }
        ],
        actor: @system
      )

      {id, "object.created", principal(opts), %{"object" => object, "id" => id}}
    end)
  end

  @doc "Changes fields of an object, as a member's patch does."
  def edit(fleet_id, id, set, opts \\ []) do
    append(fleet_id, fn seq ->
      object = Graph.read_object!(fleet_id, id, actor: @system)
      data = Map.merge(object.data, set)
      project(fleet_id, seq, object, data, object.sys)
      {id, "patch.applied", principal(opts), patch_payload(seq, object, object.data, set)}
    end)
  end

  @doc "Archives an object, as a member's archive does."
  def archive(fleet_id, id, opts \\ []) do
    append(fleet_id, fn seq ->
      object = Graph.read_object!(fleet_id, id, actor: @system)
      sys = Map.put(object.sys, "archived", true)
      project(fleet_id, seq, object, object.data, sys)
      payload = patch_payload(seq, object, %{"sys" => object.sys}, %{"sys" => sys})
      {id, "patch.applied", principal(opts), payload}
    end)
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

  defp principal(opts), do: "member:1:#{@contract}:#{by(opts)}@3/agent:#{@wallet}"
end
