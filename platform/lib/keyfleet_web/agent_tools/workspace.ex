defmodule KeyfleetWeb.AgentTools.Workspace do
  @moduledoc """
  A fleet's workspace as an agent reads it: one item as its page shows it
  (`show`), what the workspace's pages keep at hand (`board`), its items and
  links as the Graph view draws them (`view`), and its changes after a place
  in its log (`changes`). Each answers what its signed request answers
  (`KeyfleetWeb.AgentGraphController`) and refuses as it does
  (`KeyfleetWeb.WorkspaceRefusal`): a reader who is none of the fleet's
  members is told so, or that the fleet's Key ownership is being refreshed.
  Only an agent signed in on the request runs them
  (`Keyfleet.Checks.SignedInAgent`); the workspace's own policies decide every
  read (`Keyfleet.Graph.Checks.KeyReader`).
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Workspace.Read

  @bigint 9_223_372_036_854_775_807
  # Ids, names and text are passed on exactly as written; the graph checks them.
  @text [trim?: false, allow_empty?: true]
  @part "owner_key|relations|linked|url|discussion|commit|rerun_check|agents"

  actions do
    action :show, :map do
      description "One item as its page shows it, in one read: its links, its page's address, the posts its discussion names and, for a task, its commit and what a rerun still needs."
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false, constraints: @text

      argument :relations_after, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0, max: @bigint]

      # The parts besides the item to answer, comma separated; all of them
      # when left out.
      argument :fields, :string, constraints: [match: ~r/\A(?:#{@part})(?:,(?:#{@part}))*\z/]

      run {Read, read: :show}
    end

    action :board, :map do
      description "What the workspace's pages keep at hand, the whole fleet's or one project's: its newest goals and what its members pinned in its Docs and its Code."
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, constraints: @text
      run {Read, read: :board}
    end

    action :view, :map do
      description "The workspace's items, the links between them and the Keys that own them, as its Graph view draws them, each item with its page's address."
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, constraints: @text

      argument :type, :string,
        constraints: [match: ~r/\A(goal|task|finding|evidence|service|note|dead_end|review)\z/]

      argument :owner_key, :integer, constraints: [min: 1, max: @bigint]
      argument :archived, :boolean, allow_nil?: false, default: false
      run {Read, read: :view}
    end

    action :changes, :map do
      description "The workspace's changes after a place in its log, oldest first: the whole fleet's, one project's or one item's."
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, constraints: @text
      argument :object, :string, constraints: @text
      argument :max_bytes, :integer, constraints: [min: 1, max: 512 * 1024]

      argument :after_seq, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0, max: @bigint]

      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 500]
      run {Read, read: :changes}
    end
  end

  policies do
    policy always() do
      authorize_if Keyfleet.Checks.SignedInAgent
    end
  end
end
