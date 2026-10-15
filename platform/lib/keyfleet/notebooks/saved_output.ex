defmodule Keyfleet.Notebooks.SavedOutput do
  @moduledoc """
  Keyfleet's own copy of one saved notebook page, kept for good under its
  address (`Keyfleet.Notebooks.result_url/4`): the fleet, the notebook, its
  version and when the hub made the page, in milliseconds since 1970.

  A hub keeps only a notebook's newest versions, replaces a version's page
  when the same code runs again, and drops everything when a notebook is
  deleted. The copy is taken before the address is handed out
  (`KeyfleetWeb.Plugs.NotebookGateway`), so an address that was ever handed
  out keeps showing what it showed. The first copy under an address stays.
  """
  use Ash.Resource,
    domain: Keyfleet.Notebooks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "notebook_saved_outputs"
    repo(Keyfleet.Repo)
  end

  actions do
    create :keep do
      accept [:fleet_id, :notebook_id, :version_id, :saved_at, :page]
      upsert? true
      upsert_identity :unique_address
      upsert_fields []
    end

    read :at do
      get? true
      argument :fleet_id, :string, allow_nil?: false
      argument :notebook_id, :string, allow_nil?: false
      argument :version_id, :string, allow_nil?: false
      argument :saved_at, :integer, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and notebook_id == ^arg(:notebook_id) and
                 version_id == ^arg(:version_id) and saved_at == ^arg(:saved_at)
             )
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  identities do
    identity :unique_address, [:fleet_id, :notebook_id, :version_id, :saved_at]
  end

  attributes do
    uuid_primary_key :id
    attribute :fleet_id, :string, allow_nil?: false
    attribute :notebook_id, :string, allow_nil?: false
    attribute :version_id, :string, allow_nil?: false
    attribute :saved_at, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :page, :binary, allow_nil?: false
    create_timestamp :inserted_at
  end
end
