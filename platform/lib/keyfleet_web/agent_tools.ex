defmodule KeyfleetWeb.AgentTools do
  @moduledoc """
  What an agent reads and does in a fleet where the answer joins several of
  the domains' reads, or adds the addresses a person's pages show: one Ash
  action each. The signed requests' controllers answer with these actions,
  and the Claude connector's address (`/mcp`) offers them as tools named
  after their browser tools (`tools`), so both answer and refuse alike. Each
  runs as the calling agent, and the domains' own policies decide what it
  may read.
  """
  use Ash.Domain, extensions: [AshAi]

  resources do
    resource KeyfleetWeb.AgentTools.Workspace do
      define :workspace_show, action: :show, args: [:fleet_id, :id]
      define :workspace_board, action: :board, args: [:fleet_id]
      define :workspace_view, action: :view, args: [:fleet_id]
      define :workspace_changes, action: :changes, args: [:fleet_id]
    end
  end

  # Each tool keeps its browser tool's name and words; none changes anything.
  @browser_tools Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})
  @reads [
    workspace_show: {KeyfleetWeb.AgentTools.Workspace, :show, "Item"},
    workspace_board: {KeyfleetWeb.AgentTools.Workspace, :board, "Board"},
    workspace_graph: {KeyfleetWeb.AgentTools.Workspace, :view, "Graph"},
    workspace_changes: {KeyfleetWeb.AgentTools.Workspace, :changes, "Changes"}
  ]

  tools do
    for {name, {resource, action, title}} <- @reads do
      tool name, resource, action do
        title(title)
        description @browser_tools[Atom.to_string(name)]["description"]

        annotations(
          read_only_hint: true,
          idempotent_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )
      end
    end
  end
end
