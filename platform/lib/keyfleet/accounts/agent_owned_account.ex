defmodule Keyfleet.Accounts.AgentOwnedAccount do
  @moduledoc """
  The account an agent opened for itself (`Keyfleet.Accounts.AgentAccount.open/1`),
  one per agent wallet. Only an opening writes it: a person's account is never an
  agent's, whatever wallet signs the request.
  """

  use Ash.Resource,
    domain: Keyfleet.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_owned_accounts"
    repo(Keyfleet.Repo)
  end

  attributes do
    attribute :wallet_address, :string, primary_key?: true, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :human_account, Keyfleet.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  actions do
    create :record do
      accept [:wallet_address, :human_account_id]
      upsert? true
      upsert_fields [:human_account_id]
    end

    read :by_wallet do
      get? true
      argument :wallet, :string, allow_nil?: false
      filter expr(wallet_address == ^arg(:wallet))
      prepare build(load: [human_account: [:display_name, :ens_name, :ens_avatar_url]])
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end
end
