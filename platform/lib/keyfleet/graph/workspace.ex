defmodule KeyFleet.Graph.Workspace do
  @moduledoc """
  A fleet's shared workspace: the goals, tasks, findings, evidence, services,
  launch cards and notes its members keep, and the links between them.

  Each write is one operation on the fleet's graph, answered by its writer. A
  write names the key it acts as (`as_key`) and a command id of the caller's
  choosing; the same command id with the same body answers the original result
  instead of writing twice. Every object sits in a scope, the whole fleet or
  one of a Fibonacci fleet's levels, and a write may touch only objects in the
  scopes its key may write; see `KeyFleet.Graph.Checks.KeyActor`.

  Anyone may read a workspace. Reads are answered from the read tables copied
  from the graph's log, never by the writer; see `KeyFleet.Graph.Workspace.Read`.
  """
  use Ash.Resource,
    domain: KeyFleet.Graph,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyFleet.Graph.Validations.FreshOwnership
  alias KeyFleet.Graph.Validations.KnownFleet
  alias KeyFleet.Graph.Workspace.Read
  alias KeyFleet.Graph.Workspace.Relay

  @bigint 9_223_372_036_854_775_807
  # Ids, names and text are passed on exactly as written; the graph checks them.
  @text [trim?: false, allow_empty?: true]

  actions do
    action :get, :map do
      description "One object with its relations."
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false, constraints: @text
      validate KnownFleet
      run {Read, read: :get}
    end

    action :changes, :map do
      description "The workspace's changes after a place in its log, oldest first."
      argument :fleet_id, :string, allow_nil?: false

      argument :after_seq, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0, max: @bigint]

      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 500]
      validate KnownFleet
      run {Read, read: :changes}
    end

    action :create, :map do
      description "Adds an object to the scope it names."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :type, :string, allow_nil?: false, constraints: @text
      argument :scope, :string, allow_nil?: false, constraints: @text
      argument :data, :map, allow_nil?: false
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "create", body: [:type, :scope, :data]}
    end

    action :patch, :map do
      description "Changes fields of the object at the version the caller last saw."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :id, :string, allow_nil?: false, constraints: @text
      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :set, :map
      argument :unset, {:array, :string}, constraints: [items: @text]
      argument :reason, :string, constraints: @text
      argument :evidence, {:array, :string}, constraints: [items: @text]
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true

      run {Relay, op: "patch", body: [:id, :expected_version, :set, :unset, :reason, :evidence]}
    end

    action :link, :map do
      description "Relates two objects; relating them the same way again answers the existing link."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :source, :string, allow_nil?: false, constraints: @text
      argument :target, :string, allow_nil?: false, constraints: @text
      argument :type, :string, allow_nil?: false, constraints: @text
      argument :note, :string, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "link", body: [:source, :target, :type, :note]}
    end

    action :unlink, :map do
      description "Removes a relation."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :relation_id, :string, allow_nil?: false, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "unlink", body: [:relation_id]}
    end

    action :archive, :map do
      description "Archives the object at the version the caller last saw; its history stays."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :id, :string, allow_nil?: false, constraints: @text
      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :reason, :string, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "archive", body: [:id, :expected_version, :reason]}
    end
  end

  policies do
    # The workspace is public to read.
    policy action([:get, :changes]) do
      authorize_if always()
    end

    policy action([:create, :patch, :link, :unlink, :archive]) do
      authorize_if KeyFleet.Graph.Checks.KeyActor
    end
  end
end
