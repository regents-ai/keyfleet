defmodule Keyfleet.Projects.Project do
  @moduledoc """
  One project inside a fleet: its name, which addresses use and which never
  changes, and its title, which pages show.

  Its repository in the code store is named when the project starts: the
  fleet's own name for `general`, which keeps the fleet's first repository,
  and `<fleet id>-<name>` for every other. Fleet ids hold no hyphen, so no two
  projects of any fleets share a repository name. `hub_project_id` is its
  space in the fleet's notebook hub, once that is made.

  Starting a project waits its turn behind any other start in the same fleet,
  holding the fleet's `general` row, so two starts can never take one name or
  pass the most a fleet may hold together.
  """
  use Ash.Resource,
    domain: Keyfleet.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Validations.{FreshOwnership, KnownFleet}

  @most 20
  @bigint 9_223_372_036_854_775_807

  @doc "The most projects a fleet holds."
  def most, do: @most

  postgres do
    table "projects"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:name, "projects_name_shape",
        check: "name ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(name) <= 32"
      )
    end
  end

  actions do
    # The fleet's projects, oldest first, so `general` leads.
    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [inserted_at: :asc, name: :asc])
    end

    # Anyone reads the titles of a fleet's projects, oldest first; a page
    # shows the title alone.
    read :titles do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [inserted_at: :asc, name: :asc], select: [:fleet_id, :name, :title])
    end

    read :named do
      argument :fleet_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      filter expr(fleet_id == ^arg(:fleet_id) and name == ^arg(:name))
      get? true
    end

    # A member starts a project as one of the fleet's Keys.
    action :start, :struct do
      constraints instance_of: __MODULE__
      argument :fleet_id, :string, allow_nil?: false
      argument :as_key, :integer, allow_nil?: false, constraints: [min: 0, max: @bigint]
      argument :name, :string, allow_nil?: false, constraints: [trim?: false]
      argument :title, :string, allow_nil?: false
      validate KnownFleet
      validate FreshOwnership

      run fn input, %{actor: actor} ->
        %{fleet_id: fleet_id, as_key: as_key} = input.arguments
        within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

        with {:ok, _command} <- KeyActor.command(actor, fleet_id, as_key, nil, within) do
          __MODULE__
          |> Ash.Changeset.for_create(
            :create,
            %{fleet_id: fleet_id, name: input.arguments.name, title: input.arguments.title},
            actor: %Keyfleet.Actors.System{}
          )
          |> Ash.Changeset.force_change_attribute(:created_by_key, as_key)
          |> Ash.create()
        end
      end
    end

    create :create do
      public? false
      accept [:fleet_id, :name, :title]
      validate KnownFleet
      change Keyfleet.Projects.Changes.Room
    end
  end

  policies do
    policy action(:start) do
      authorize_if KeyActor
    end

    policy action(:titles) do
      authorize_if always()
    end

    policy action([:in_fleet, :named]) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if Keyfleet.Graph.Checks.KeyReader
    end

    policy action(:create) do
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
    attribute :repository, :string, allow_nil?: false, public?: true
    attribute :hub_project_id, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  identities do
    identity :one_repository, [:repository]
  end
end
