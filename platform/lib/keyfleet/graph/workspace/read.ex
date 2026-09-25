defmodule Keyfleet.Graph.Workspace.Read do
  @moduledoc """
  Answers a workspace read from the fleet's read tables, never from its
  writer, so a read never waits behind a write.

  Each read is answered from one read-only snapshot of the tables, so it
  shows the workspace exactly as it stood at `watermark`, the place in the
  fleet's log the tables had reached: a write whose `head_seq` is at or below
  it is in the answer, and nothing past it is.

  `get` answers one object and its first 200 links, and for a launch plan
  the digest of the version it answers, `launch_digest`, the value a launch
  proposal carries to point to that version (see
  `Keyfleet.Graph.LaunchPlanDigest`); it is null for every other type.
  `changes` answers the copied events after `after_seq`, oldest first, at
  most `limit` of them and no more than 512 KiB of them unless one event
  alone is larger; `next_cursor` is the `after_seq` to read on from, and
  `run_id` names the log they come from.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Event

  @relation_page 200
  @tables [Graph.Cursor, Graph.Event, Graph.Object, Graph.Relation, Graph.LaunchPlanRevision]

  @impl true
  def run(input, opts, context) do
    kind = Keyword.fetch!(opts, :read)
    in_snapshot(fn -> read(kind, input.arguments, actor: context.actor) end)
  end

  # Postgres fixes a repeatable-read snapshot at the transaction's first
  # query, so everything read after this setting comes from one moment.
  defp in_snapshot(read) do
    Ash.transact(@tables, fn ->
      Keyfleet.Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
      read.()
    end)
  end

  defp read(:get, %{fleet_id: fleet_id, id: id}, opts) do
    {_run_id, watermark} = standing(fleet_id, opts)

    case Graph.read_object!(fleet_id, id, opts) do
      nil ->
        {:error,
         RefusedError.exception(code: "not_found", reason: "no such object", details: %{id: id})}

      object ->
        relations = Graph.read_relations_touching!(fleet_id, id, @relation_page + 1, opts)

        %{
          object: Map.take(object, [:id, :type, :data, :sys, :version]),
          relations:
            relations
            |> Enum.take(@relation_page)
            |> Enum.map(&Map.take(&1, [:id, :type, :source, :target, :data])),
          relations_has_more: length(relations) > @relation_page,
          launch_digest: launch_digest(object, opts),
          watermark: watermark
        }
    end
  end

  defp read(:changes, %{fleet_id: fleet_id, after_seq: after_seq, limit: limit}, opts) do
    {run_id, watermark} = standing(fleet_id, opts)
    page = fleet_id |> Graph.read_events!(after_seq, limit, opts) |> Enum.map(&Event.view/1)
    has_more = page != [] and more_after?(fleet_id, List.last(page).seq, opts)

    %{
      run_id: run_id,
      events: page,
      next_cursor: if(has_more, do: List.last(page).seq, else: max(after_seq, watermark)),
      has_more: has_more,
      watermark: watermark
    }
  end

  # The projector writes a launch plan's revision with the object, so the
  # version read has one.
  defp launch_digest(%{type: "launch_card"} = plan, opts) do
    [%{digest: digest}] =
      Graph.current_launch_plan_revisions!(
        plan.fleet_id,
        [%{object_id: plan.id, version: plan.version}],
        opts
      )

    digest
  end

  defp launch_digest(_object, _opts), do: nil

  # A fleet whose log has never been copied reads as an empty log.
  defp standing(fleet_id, opts) do
    case Graph.get_cursor!(fleet_id, opts) do
      nil -> {nil, 0}
      cursor -> {cursor.run_id, cursor.applied_seq}
    end
  end

  defp more_after?(fleet_id, seq, opts) do
    Event
    |> Ash.Query.for_read(:page, %{fleet_id: fleet_id, after_seq: seq, limit: 1}, opts)
    |> Ash.exists?(opts)
  end
end
