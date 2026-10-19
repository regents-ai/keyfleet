defmodule Keyfleet.Graph.Workspace do
  @moduledoc """
  A fleet's shared workspace: the goals, tasks, findings, evidence, services,
  notes and dead ends its members keep, the links between them, and the
  reviews of submitted tasks. A member joins a goal to follow it: the goal
  records each Key and wallet that joined, and a member's sync lists the
  goals it joined.

  A task is marked done only by submitting it (`submit`), with its result and
  the evidence it rests on. A submission claims the work is done; whether it
  is accepted is for other members' reviews (`review`) to say, each bound to
  the task version it judged. Neither says anything about paying for it.

  Each write is one operation on the fleet's graph, answered by its writer. A
  write names the key it acts as (`as_key`) and a command id of the caller's
  choosing; the same command id with the same body answers the original result
  instead of writing twice. Every object sits in a scope, the whole fleet or
  one of a Fibonacci fleet's levels, and a write may touch only objects in the
  scopes its key may write; see `Keyfleet.Graph.Checks.KeyActor`.

  Only the fleet's members read a workspace: whoever owns one of its keys
  today, an agent holding an active shard of one, or an agent paired with a
  person who owns one; see
  `Keyfleet.Graph.Checks.KeyReader`. Reads are answered from the read tables
  copied from the graph's log, never by the writer; see
  `Keyfleet.Graph.Workspace.Read`.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Graph.Validations.FreshOwnership
  alias Keyfleet.Graph.Validations.KnownFleet
  alias Keyfleet.Graph.Workspace.Read
  alias Keyfleet.Graph.Workspace.Relay

  @bigint 9_223_372_036_854_775_807
  # Ids, names and text are passed on exactly as written; the graph checks them.
  @text [trim?: false, allow_empty?: true]

  actions do
    action :get, :map do
      description "One object with a page of its relations."
      argument :fleet_id, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false, constraints: @text

      argument :relations_after, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0, max: @bigint]

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

    action :submit, :map do
      description "Submits a task for review: marks it done with its result and links its evidence."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :id, :string, allow_nil?: false, constraints: @text
      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :result_ref, :string, constraints: @text
      argument :evidence, {:array, :string}, constraints: [items: @text]
      argument :reason, :string, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "submit", body: [:id, :expected_version, :result_ref, :evidence, :reason]}
    end

    action :review, :map do
      description "Records a member's decision on the submitted task version they read."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :task, :string, allow_nil?: false, constraints: @text
      argument :task_version, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :decision, :string, allow_nil?: false, constraints: @text
      argument :rationale, :string, allow_nil?: false, constraints: @text
      argument :conflicts_of_interest, :string, allow_nil?: false, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true

      run {Relay,
           op: "review",
           body: [:task, :task_version, :decision, :rationale, :conflicts_of_interest]}
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

    action :join, :map do
      description "Joins a goal as the acting Key and wallet; joining again changes nothing."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :id, :string, allow_nil?: false, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "join", body: [:id]}
    end

    action :leave, :map do
      description "Leaves a goal the acting Key and wallet joined; leaving again changes nothing."
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]
      argument :command_id, :string, allow_nil?: false, constraints: @text
      argument :id, :string, allow_nil?: false, constraints: @text
      validate KnownFleet
      validate FreshOwnership, only_when_valid?: true
      run {Relay, op: "leave", body: [:id]}
    end
  end

  policies do
    policy action([:get, :changes]) do
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action([:create, :patch, :link, :unlink, :archive, :join, :leave, :submit, :review]) do
      authorize_if Keyfleet.Graph.Checks.KeyActor
    end
  end
end
