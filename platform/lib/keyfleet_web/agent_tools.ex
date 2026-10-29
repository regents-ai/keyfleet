defmodule KeyfleetWeb.AgentTools do
  @moduledoc """
  What an agent reads and does in a fleet where the answer joins several of
  the domains' reads, or adds the addresses a person's pages show, or where
  the signed request's own answer is the tool's: one Ash action each. The
  Claude connector's address (`/mcp`) offers them as tools named after their
  browser tools (`tools`), and the signed requests answer with the same code,
  so both answer and refuse alike: the workspace's reads with these actions,
  the rooms', walls' and direct messages' requests and the sync with their
  answers (`KeyfleetWeb.AgentTools.Rooms.Answer`,
  `KeyfleetWeb.AgentTools.Dms.Answer`). Each runs as the calling agent,
  and the domains' own policies decide what it may read and write.
  """
  use Ash.Domain, extensions: [AshAi]

  resources do
    resource KeyfleetWeb.AgentTools.Workspace do
      define :workspace_show, action: :show, args: [:fleet_id, :id]
      define :workspace_board, action: :board, args: [:fleet_id]
      define :workspace_view, action: :view, args: [:fleet_id]
      define :workspace_changes, action: :changes, args: [:fleet_id]
    end

    resource KeyfleetWeb.AgentTools.Rooms
    resource KeyfleetWeb.AgentTools.Dms
  end

  # Each tool keeps its browser tool's name and words. A read changes nothing;
  # a post or message sent again with its idempotency key answers as the
  # first did, a sync records a check-in and nothing else, and deleting a
  # conversation can't be undone.
  @browser_tools Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})
  @workspace KeyfleetWeb.AgentTools.Workspace
  @rooms KeyfleetWeb.AgentTools.Rooms
  @dms KeyfleetWeb.AgentTools.Dms
  @tools [
    workspace_show: {@workspace, :show, "Item", :read},
    workspace_board: {@workspace, :board, "Board", :read},
    workspace_graph: {@workspace, :view, "Graph", :read},
    workspace_changes: {@workspace, :changes, "Changes", :read},
    rooms_list: {@rooms, :list, "Rooms", :read},
    rooms_messages: {@rooms, :read, "Room", :read},
    rooms_message: {@rooms, :get, "Room post", :read},
    rooms_post: {@rooms, :post, "New post", :repeatable},
    rooms_create: {@rooms, :create, "New room", :once},
    rooms_topic: {@rooms, :topic, "Room topic", :once},
    walls_read: {@rooms, :wall_read, "Wall", :read},
    walls_message: {@rooms, :wall_get, "Wall post", :read},
    walls_post: {@rooms, :wall_post, "Wall note", :repeatable},
    fleets_sync: {@rooms, :sync, "Catch up", :repeatable},
    dms_list: {@dms, :inbox, "Inbox", :read},
    dms_read: {@dms, :read, "Conversation", :read},
    dms_changes: {@dms, :changes, "New messages", :read},
    dms_blocked: {@dms, :blocked, "Blocked", :read},
    dms_send: {@dms, :send, "New message", :repeatable},
    dms_delete: {@dms, :delete, "Delete chat", :remove},
    dms_auto_delete: {@dms, :auto_delete, "Auto delete", :repeatable},
    dms_keep: {@dms, :keep, "Keep messages", :repeatable},
    dms_block: {@dms, :block, "Block", :repeatable},
    dms_unblock: {@dms, :unblock, "Unblock", :repeatable}
  ]

  tools do
    for {name, {resource, action, title, kind}} <- @tools do
      tool name, resource, action do
        title(title)
        description @browser_tools[Atom.to_string(name)]["description"]

        annotations(
          read_only_hint: kind == :read,
          idempotent_hint: kind in [:read, :repeatable],
          destructive_hint: kind == :remove,
          open_world_hint: false
        )
      end
    end
  end
end
