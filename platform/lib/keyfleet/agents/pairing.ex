defmodule Keyfleet.Agents.Pairing do
  @moduledoc """
  Which person an agent's wallet is paired with, and the name the agent goes
  by, read from the table the agent pairing every Regent site shares keeps
  (`RegentAgents.PairedAgent`). Pairing and unpairing happen only through
  `RegentAgents`, with a code the person makes on their Agents page here or
  on regents.sh; this module only looks wallets up, as the system: one when
  that agent signs a request, and several for the names the workspace pulse
  tells.
  """

  use Ash.Resource,
    domain: Keyfleet.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "paired_agents"
    schema("regent_agents")
    repo(Keyfleet.Repo)
    migrate?(false)
  end

  attributes do
    uuid_primary_key :id
    attribute :wallet, :string, allow_nil?: false
    attribute :privy_user_id, :string, allow_nil?: false, sensitive?: true
    attribute :name, :string, allow_nil?: false
  end

  actions do
    read :by_wallet do
      get_by :wallet
    end

    read :by_wallets do
      argument :wallets, {:array, :string}, allow_nil?: false
      filter expr(wallet in ^arg(:wallets))
      prepare build(select: [:wallet, :name])
    end
  end

  policies do
    policy action([:by_wallet, :by_wallets]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end
end
