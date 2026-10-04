defmodule Keyfleet.Code.Repository do
  @moduledoc """
  A fleet's repository in the code store, as this site made it: the owner the
  store keeps it under, which every address in the store names. Recorded once,
  when the repository is made (`Keyfleet.Code.Setup`).
  """
  use Ash.Resource,
    domain: Keyfleet.Code,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "code_repositories"
    repo(Keyfleet.Repo)
  end

  actions do
    defaults [:read]

    create :record do
      accept [:fleet_id, :owner]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :owner, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
