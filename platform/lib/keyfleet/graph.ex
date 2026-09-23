defmodule KeyFleet.Graph do
  @moduledoc """
  Each fleet's shared workspace, kept in the fleet's own graph.

  Every call names its fleet. Writes go to the fleet's graph; a write names the
  key it acts as, `as_key`, and its own command id; see
  `KeyFleet.Graph.Workspace`. Reads are open to anyone and are answered from
  read tables the projector keeps copied from the graph's log, so a read never
  waits on a write. Each read says how far along the log it reflects, its
  `watermark`.
  """
  use Ash.Domain

  resources do
    resource KeyFleet.Graph.Workspace do
      define :get_object, action: :get, args: [:fleet_id, :id]
      define :list_changes, action: :changes, args: [:fleet_id]
      define :create_object, action: :create, args: [:fleet_id]
      define :patch_object, action: :patch, args: [:fleet_id]
      define :link_objects, action: :link, args: [:fleet_id]
      define :unlink_relation, action: :unlink, args: [:fleet_id]
      define :archive_object, action: :archive, args: [:fleet_id]
    end

    resource KeyFleet.Graph.Cursor do
      define :get_cursor, action: :read, get_by: [:fleet_id], not_found_error?: false
      define :start_cursor, action: :start
      define :advance_cursor, action: :advance
      define :forget_cursor, action: :forget
    end

    resource KeyFleet.Graph.Event do
      define :read_events, action: :page, args: [:fleet_id, :after_seq, :limit]
      define :latest_activity, action: :activity, args: [:fleet_id]
      define :object_history, action: :history, args: [:fleet_id, :object_id]
      define :record_events, action: :record
    end

    resource KeyFleet.Graph.Object do
      define :read_object, action: :in_fleet, args: [:fleet_id, :id], not_found_error?: false
      define :read_objects, action: :with_ids, args: [:fleet_id, :ids]
      define :workspace_cards, action: :cards, args: [:fleet_id]
      define :object_titles, action: :titled, args: [:fleet_id, :ids]
      define :project_objects, action: :project
    end

    resource KeyFleet.Graph.Relation do
      define :read_relations_touching, action: :touching, args: [:fleet_id, :object_id, :limit]
      define :object_links, action: :linked, args: [:fleet_id, :object_id]
      define :project_relations, action: :project
      define :remove_relations, action: :remove
    end
  end

  @doc """
  Where a fleet says how far its workspace's read tables have reached, as
  `{:graph_head, fleet_id, run_id, watermark}`: the log they copy and the
  place in it. A notice is only a hint to read again; a reader that misses one
  loses nothing, because it reads on from its own cursor.
  """
  def head_topic(fleet_id), do: "fleet:#{fleet_id}:graph"
end
