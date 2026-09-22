defmodule KeyFleet.Graph do
  @moduledoc """
  Each fleet's shared workspace, kept in the fleet's own graph.

  Every call names its fleet. Reads are open to anyone. A write names the key
  it acts as, `as_key`, and its own command id; see `KeyFleet.Graph.Workspace`.
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
  end
end
