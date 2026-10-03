defmodule Keyfleet.Notebooks.Hub do
  @moduledoc """
  A fleet's notebook hub as this site set it up: the project in that hub the
  fleet's key holders work in. Recorded once, the first time the site sets the
  hub up (`Keyfleet.Notebooks.Roster`).
  """
  use Ash.Resource,
    domain: Keyfleet.Notebooks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "notebook_hubs"
    repo(Keyfleet.Repo)
  end

  actions do
    defaults [:read]

    create :record do
      accept [:fleet_id, :project_id]
    end
  end

  policies do
    policy always() do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :project_id, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
