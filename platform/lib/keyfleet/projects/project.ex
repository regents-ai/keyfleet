defmodule Keyfleet.Projects.Project do
  @moduledoc """
  One project inside a fleet: its name, which addresses use and which never
  changes, its title, which pages show, the Key that holds it (`key`, by
  number) and its state: `active`, `archived` or `deleted`.

  A Key holds at most one active project and five archived ones. It starts a
  project when it holds no active one (`start`), archives its active one
  (`archive`), takes over any archived project when it holds no active one
  (`take_over`), and deletes one of its own archived projects (`delete`):
  the row stays, marked deleted, so its name and repository name are never
  used again, and everything else of it goes (`Keyfleet.Projects.Hold`).
  Projects stay with the Key's number when the Key changes hands. Only an
  active project takes new work.

  Its repository in the code store is named when the project starts: the
  fleet's own name for `general`, which keeps the fleet's first repository,
  and `<fleet id>-<name>` for every other. Fleet ids hold no hyphen, so no two
  projects of any fleets share a repository name; a job queued as the
  project starts makes it there (`Keyfleet.Code.Setup`). `hub_project_id` is its
  space in the fleet's notebook hub, once a job has made it
  (`Keyfleet.Notebooks.Space`).

  Every fleet has `general`, archived and held by Key 3, which holds the
  starting goals, the fleet's first notebook space and its first repository
  (`bootstrap_general`).
  """
  use Ash.Resource,
    domain: Keyfleet.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Validations.{FreshOwnership, KnownFleet}
  alias Keyfleet.Projects.Hold

  @bigint 9_223_372_036_854_775_807
  @states [:active, :archived, :deleted]
  # The most archived projects one Key holds.
  @archived_most 5
  # The Key that holds `general`.
  @general_key 3

  @doc "The most archived projects one Key holds."
  def archived_most, do: @archived_most

  postgres do
    table "projects"
    repo(Keyfleet.Repo)

    identity_wheres_to_sql(one_active_per_key: "state = 'active'")

    check_constraints do
      check_constraint(:name, "projects_name_shape",
        check: "name ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(name) <= 32"
      )

      check_constraint(:state, "projects_state",
        check: "state IN ('active', 'archived', 'deleted')"
      )
    end
  end

  actions do
    # The read a guarded change of state reads its row back with.
    read :read do
      primary? true
      public? false
    end

    # The fleet's projects, oldest first, so `general` leads; a deleted one
    # is left out.
    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and state != :deleted)
      prepare build(sort: [inserted_at: :asc, name: :asc])
    end

    # Anyone reads the titles of a fleet's projects, oldest first; a page
    # shows the title alone.
    read :titles do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and state != :deleted)
      prepare build(sort: [inserted_at: :asc, name: :asc], select: [:fleet_id, :name, :title])
    end

    read :named do
      argument :fleet_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      filter expr(fleet_id == ^arg(:fleet_id) and name == ^arg(:name) and state != :deleted)
      get? true
    end

    # The fleet's project by name in any state, deleted included, for the
    # names that are never used again.
    read :ever_named do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      filter expr(fleet_id == ^arg(:fleet_id) and name == ^arg(:name))
      get? true
    end

    # The projects one Key holds in one state, oldest first.
    read :held do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :key, :integer, allow_nil?: false
      argument :state, :atom, allow_nil?: false, constraints: [one_of: @states]
      filter expr(fleet_id == ^arg(:fleet_id) and key == ^arg(:key) and state == ^arg(:state))
      prepare build(sort: [inserted_at: :asc, name: :asc])
    end

    # The project whose repository git asks for by name.
    read :by_repository do
      argument :repository, :string, allow_nil?: false, constraints: [trim?: false]
      filter expr(repository == ^arg(:repository) and state != :deleted)
      get? true
    end

    # A member starts a project as one of the fleet's Keys, which holds it.
    action :start, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      argument :title, :string, allow_nil?: false
      validate KnownFleet
      validate FreshOwnership
      run {Hold, step: :start}
    end

    # The Key's active project becomes archived, still the Key's.
    action :archive, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      validate KnownFleet
      validate FreshOwnership
      run {Hold, step: :archive}
    end

    # An archived project, any Key's, becomes the acting Key's active one.
    action :take_over, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      validate KnownFleet
      validate FreshOwnership
      run {Hold, step: :take_over}
    end

    # One of the acting Key's own archived projects is deleted for good.
    action :delete, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      validate KnownFleet
      validate FreshOwnership
      run {Hold, step: :delete}
    end

    create :create do
      public? false
      accept [:fleet_id, :name, :title, :key]
      validate KnownFleet
      change set_attribute(:state, :active)

      change fn changeset, _context ->
        %{fleet_id: fleet_id, name: name, key: key} = changeset.attributes

        Ash.Changeset.force_change_attributes(changeset,
          created_by_key: key,
          repository: "#{fleet_id}-#{name}"
        )
      end

      change Keyfleet.Notebooks.Changes.MakeSpace
      change Keyfleet.Code.Changes.MakeRepository
    end

    # Gives a fleet its `general` once; a fleet that has it keeps it as it is.
    create :general do
      public? false
      accept [:fleet_id]
      upsert? true
      upsert_fields [:title]

      change fn changeset, _context ->
        Ash.Changeset.force_change_attributes(changeset,
          name: "general",
          title: "General",
          key: @general_key,
          state: :archived,
          repository: Ash.Changeset.get_attribute(changeset, :fleet_id)
        )
      end
    end

    update :archived do
      public? false
      accept []
      change filter(expr(state == :active))
      change set_attribute(:state, :archived)
    end

    update :taken_over do
      public? false
      accept []
      argument :key, :integer, allow_nil?: false
      change filter(expr(state == :archived))
      change set_attribute(:key, arg(:key))
      change set_attribute(:state, :active)
    end

    update :deleted do
      public? false
      accept []
      argument :key, :integer, allow_nil?: false
      require_atomic? false
      change filter(expr(state == :archived and key == ^arg(:key)))
      change set_attribute(:state, :deleted)
      change Keyfleet.Projects.Changes.Forget
    end

    update :record_space do
      accept [:hub_project_id]
      require_atomic? false
      change Keyfleet.Notebooks.Changes.QueueRoster
    end
  end

  policies do
    policy action([:start, :archive, :take_over, :delete]) do
      authorize_if KeyActor
    end

    policy action(:titles) do
      authorize_if always()
    end

    policy action([:in_fleet, :named]) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action([
             :read,
             :create,
             :general,
             :ever_named,
             :held,
             :archived,
             :taken_over,
             :deleted,
             :record_space,
             :by_repository
           ]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :name, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32, trim?: false]

    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 60, match: ~r/\A[^\x00-\x1f\x7f]*\z/]

    # The Key that started it; none for `general`, which every fleet starts with.
    attribute :created_by_key, :integer, public?: true
    attribute :key, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :state, :atom, allow_nil?: false, public?: true, constraints: [one_of: @states]
    attribute :repository, :string, allow_nil?: false, public?: true
    attribute :hub_project_id, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  identities do
    identity :one_repository, [:repository]

    identity :one_active_per_key, [:fleet_id, :key],
      where: expr(state == :active),
      message: "this Key is already working on a project"
  end
end
