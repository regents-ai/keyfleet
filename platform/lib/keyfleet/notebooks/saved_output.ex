defmodule Keyfleet.Notebooks.SavedOutput do
  @moduledoc """
  Keyfleet's own copy of one saved notebook page, kept under its address
  (`Keyfleet.Notebooks.result_url/4`): the fleet, the notebook, the version
  or background run that made the page, and when the hub made it, in
  milliseconds since 1970.

  A hub keeps only a notebook's newest versions and recent runs, replaces a
  version's page when the same code runs again, and drops everything when a
  notebook is deleted. The copy is taken before the address is handed out
  (`KeyfleetWeb.Plugs.NotebookGateway`), so an address that was ever handed
  out keeps showing what it showed. The first copy under an address stays,
  until one of the fleet's members removes it; the address is then gone.
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
      accept [:fleet_id, :notebook_id, :source_id, :saved_at, :page]
      upsert? true
      upsert_identity :unique_address
      upsert_fields []
    end

    destroy :remove

    read :at do
      get? true
      argument :fleet_id, :string, allow_nil?: false
      argument :notebook_id, :string, allow_nil?: false
      argument :source_id, :string, allow_nil?: false
      argument :saved_at, :integer, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and notebook_id == ^arg(:notebook_id) and
                 source_id == ^arg(:source_id) and saved_at == ^arg(:saved_at)
             )
    end

    # Where the fleet's copies made by any of `source_ids` are kept, without
    # their pages.
    read :of_sources do
      argument :fleet_id, :string, allow_nil?: false
      argument :source_ids, {:array, :string}, allow_nil?: false

      filter expr(fleet_id == ^arg(:fleet_id) and source_id in ^arg(:source_ids))
      prepare build(select: [:notebook_id, :source_id, :saved_at])
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  identities do
    identity :unique_address, [:fleet_id, :notebook_id, :source_id, :saved_at]
  end

  attributes do
    uuid_primary_key :id
    attribute :fleet_id, :string, allow_nil?: false
    attribute :notebook_id, :string, allow_nil?: false
    attribute :source_id, :string, allow_nil?: false
    attribute :saved_at, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :page, :binary, allow_nil?: false
    create_timestamp :inserted_at
  end
end
