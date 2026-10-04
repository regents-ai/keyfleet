defmodule Keyfleet.Code.Push do
  @moduledoc """
  One branch or tag a key's holder moved in the fleet's code: which key, the
  wallet holding it, the branch or tag and the commit it now points at. The
  store accepted each one recorded (`KeyfleetWeb.Plugs.CodeGateway`). Anyone
  may read them; the code itself stays with the fleet's key holders.
  """
  use Ash.Resource,
    domain: Keyfleet.Code,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "code_pushes"
    repo(Keyfleet.Repo)

    custom_indexes do
      index([:fleet_id, :pushed_at])
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:fleet_id, :token_id, :wallet, :ref, :head]
    end

    read :recent do
      argument :fleet_id, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [pushed_at: :desc], limit: 10)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :fleet_id, :string, allow_nil?: false, public?: true
    attribute :token_id, :integer, allow_nil?: false, public?: true
    attribute :wallet, :string, allow_nil?: false, public?: true
    attribute :ref, :string, allow_nil?: false, public?: true
    attribute :head, :string, allow_nil?: false, public?: true
    create_timestamp :pushed_at, public?: true
  end
end
