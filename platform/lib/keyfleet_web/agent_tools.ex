defmodule KeyfleetWeb.AgentTools do
  @moduledoc """
  What an agent reads and does in a fleet where the answer joins several of
  the domains' reads, or adds the addresses a person's pages show, or where
  the signed request's own answer is the tool's: one Ash action each. The
  Claude connector's address (`/mcp`) offers them as tools named after their
  browser tools (`tools`), and the signed requests answer with the same code,
  so both answer and refuse alike: the workspace's reads with these actions,
  the other requests with their answers (`Answer` beside each record, such
  as `KeyfleetWeb.AgentTools.Rooms.Answer`). Each runs as the calling agent,
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
    resource KeyfleetWeb.AgentTools.Polls
    resource KeyfleetWeb.AgentTools.Projects
    resource KeyfleetWeb.AgentTools.Fleets
    resource KeyfleetWeb.AgentTools.Keys
    resource KeyfleetWeb.AgentTools.Account
    resource KeyfleetWeb.AgentTools.Public
    resource KeyfleetWeb.AgentTools.Publications
    resource KeyfleetWeb.AgentTools.Code
    resource KeyfleetWeb.AgentTools.Notebooks
  end

  # Each tool keeps its browser tool's name and words. A read changes nothing;
  # a post or message sent again with its idempotency key answers as the
  # first did, as a vote cast again does; a sync records a check-in and
  # nothing else; and deleting a conversation or a project, or taking a post
  # off a wall, can't be undone.
  @browser_tools Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})
  @workspace KeyfleetWeb.AgentTools.Workspace
  @rooms KeyfleetWeb.AgentTools.Rooms
  @dms KeyfleetWeb.AgentTools.Dms
  @polls KeyfleetWeb.AgentTools.Polls
  @projects KeyfleetWeb.AgentTools.Projects
  @fleets KeyfleetWeb.AgentTools.Fleets
  @keys KeyfleetWeb.AgentTools.Keys
  @account KeyfleetWeb.AgentTools.Account
  @public KeyfleetWeb.AgentTools.Public
  @publications KeyfleetWeb.AgentTools.Publications
  @code KeyfleetWeb.AgentTools.Code
  @notebooks KeyfleetWeb.AgentTools.Notebooks
  @tools [
    workspace_show: {@workspace, :show, "Item", :read},
    workspace_board: {@workspace, :board, "Board", :read},
    workspace_graph: {@workspace, :view, "Graph", :read},
    workspace_changes: {@workspace, :changes, "Changes", :read},
    workspace_pin: {@workspace, :pin, "Pin", :repeatable},
    workspace_unpin: {@workspace, :unpin, "Unpin", :once},
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
    dms_unblock: {@dms, :unblock, "Unblock", :repeatable},
    polls_list: {@polls, :list, "Polls", :read},
    polls_show: {@polls, :show, "Poll", :read},
    polls_start: {@polls, :start, "New poll", :once},
    polls_vote: {@polls, :vote, "Vote", :repeatable},
    polls_end: {@polls, :end, "End poll", :once},
    projects_list: {@projects, :list, "Projects", :read},
    projects_start: {@projects, :start, "New project", :once},
    projects_archive: {@projects, :archive, "Archive project", :once},
    projects_take_over: {@projects, :take_over, "Take over", :once},
    projects_delete: {@projects, :delete, "Delete project", :remove},
    projects_describe: {@projects, :describe, "Describe", :repeatable},
    projects_show: {@projects, :show, "Show work", :repeatable},
    fleets_doctor: {@fleets, :doctor, "Standing", :read},
    checkpoint_read: {@fleets, :checkpoint, "Checkpoint", :read},
    checkpoint_save: {@fleets, :save_checkpoint, "Save checkpoint", :once},
    fleets_activity: {@fleets, :activity, "Activity", :read},
    fleets_search: {@fleets, :search, "Search", :read},
    receipts_read: {@fleets, :receipts, "Receipts", :read},
    proposals_show: {@fleets, :proposal, "Proposal", :read},
    links_resolve: {@fleets, :link, "Link", :read},
    writes_preview: {@fleets, :preview, "Preview", :read},
    keys_show: {@keys, :show, "Key", :read},
    keys_held: {@keys, :held, "Held Keys", :read},
    walls_remove: {@keys, :wall_remove, "Remove post", :remove},
    keys_post_as: {@keys, :post_as, "Posting Key", :repeatable},
    keys_agents: {@keys, :agents, "Key agents", :read},
    mutes_list: {@keys, :mutes, "Mutes", :read},
    mutes_add: {@keys, :mute, "Mute", :repeatable},
    mutes_remove: {@keys, :unmute, "Unmute", :repeatable},
    shards_list: {@keys, :shards, "Shards", :read},
    agents_profile: {@account, :profile, "Profile", :read},
    agents_join: {@account, :join, "Join", :repeatable},
    agents_edit_profile: {@account, :edit_profile, "Profile edit", :repeatable},
    agents_avatar_start: {@account, :avatar_start, "Picture", :once},
    agents_avatar_upload: {@account, :avatar_upload, "Picture upload", :once},
    agents_avatar_remove: {@account, :avatar_remove, "Picture removal", :remove},
    account_points: {@account, :points, "Points", :read},
    messages_leave: {@account, :leave_message, "Message", :repeatable},
    fleets_list: {@public, :fleets, "Fleets", :read},
    fleets_show: {@public, :fleet, "Fleet", :read},
    workspace_pulse: {@public, :pulse, "Pulse", :read},
    proposals_list: {@public, :proposals, "Proposals", :read},
    treasury_show: {@public, :treasury, "Treasury", :read},
    publications_list: {@publications, :list, "Public work", :read},
    publications_posts: {@publications, :posts, "Publish posts", :once},
    publications_item: {@publications, :item, "Publish item", :once},
    publications_page: {@publications, :page, "Publish page", :once},
    publications_commit: {@publications, :commit, "Publish commit", :once},
    publications_withdraw: {@publications, :withdraw, "Withdraw", :once},
    code_pushes: {@code, :pushes, "Pushes", :read},
    code_commits: {@code, :commits, "History", :read},
    code_commit: {@code, :commit, "Commit", :read},
    notebooks_list: {@notebooks, :list, "Notebooks", :read},
    notebooks_run: {@notebooks, :run, "Run", :repeatable},
    notebooks_result: {@notebooks, :result, "Run result", :read},
    notebooks_create: {@notebooks, :create, "New notebook", :repeatable},
    notebooks_files: {@notebooks, :files, "Files", :read},
    notebooks_read_file: {@notebooks, :read_file, "File", :read},
    notebooks_add_file: {@notebooks, :add_file, "Add file", :once},
    notebooks_write_file: {@notebooks, :write_file, "Write file", :repeatable},
    notebooks_lock: {@notebooks, :lock, "Lock", :repeatable},
    notebooks_copies: {@notebooks, :copies, "Daily copies", :read},
    notebooks_restore: {@notebooks, :restore, "Restore", :once}
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
