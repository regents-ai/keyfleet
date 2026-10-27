defmodule Keyfleet.Code.Push do
  @moduledoc """
  One branch or tag a key's holder moved in one project's repository: which
  key, the wallet holding it, the branch or tag and the commit it now points
  at. The store accepted each one recorded (`KeyfleetWeb.Plugs.CodeGateway`).
  They are read as the code is, by the fleet's members (`Keyfleet.Access`,
  `:code`).
  """
  use Ash.Resource,
    domain: Keyfleet.Code,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "code_pushes"
    repo(Keyfleet.Repo)

    custom_indexes do
      index([:fleet_id, :project, :pushed_at])
    end
  end

  actions do
    create :record do
      accept [
        :fleet_id,
        :project,
        :token_id,
        :wallet,
        :ref,
        :head,
        :acting_agent_wallet,
        :beneficiary_privy_user_id,
        :agent_pairing_id
      ]
    end

    read :recent do
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and project == ^arg(:project))
      prepare build(sort: [pushed_at: :desc], limit: 10)
    end

    # The pushes that left a branch or tag at `head`, oldest first: who sent
    # that commit to the project's repository, where and when.
    read :of_commit do
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      argument :head, :string, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and project == ^arg(:project) and head == ^arg(:head)
             )

      prepare build(sort: [pushed_at: :asc], limit: 20)
    end
  end

  policies do
    policy action([:recent, :of_commit]) do
      authorize_if {Keyfleet.Access.Check, read: :code, scope: :fleet_id}
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :acting_agent_wallet, :string
    attribute :beneficiary_privy_user_id, :string, sensitive?: true
    attribute :agent_pairing_id, :uuid
    uuid_primary_key :id
    attribute :fleet_id, :string, allow_nil?: false, public?: true
    attribute :project, :string, allow_nil?: false, public?: true
    attribute :token_id, :integer, allow_nil?: false, public?: true
    attribute :wallet, :string, allow_nil?: false, public?: true
    attribute :ref, :string, allow_nil?: false, public?: true
    attribute :head, :string, allow_nil?: false, public?: true
    create_timestamp :pushed_at, public?: true
  end
end
