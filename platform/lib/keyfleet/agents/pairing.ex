defmodule Keyfleet.Agents.Pairing do
  @moduledoc """
  Which person an agent's wallet is paired with, read from the table the agent
  pairing every Regent site shares keeps (`RegentAgents.PairedAgent`). Pairing
  and unpairing happen only through `RegentAgents`, with a code the person makes
  with Pair New Agent in the side panel here or on regents.sh; this module only looks a wallet
  up, as the system, when that agent signs a request.
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
  end

  actions do
    read :by_wallet do
      get_by :wallet
    end
  end

  policies do
    policy action(:by_wallet) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end
end
