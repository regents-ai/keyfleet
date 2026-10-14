defmodule Keyfleet.Accounts.LinkedIdentity do
  @moduledoc "A social account Privy verified for one human account, one per provider."

  use Ash.Resource,
    domain: Keyfleet.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "linked_identities"
    repo(Keyfleet.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:x, :github, :farcaster]]

    attribute :subject, :string, allow_nil?: false
    attribute :username, :string, public?: true
    attribute :display_name, :string, public?: true
    attribute :verified_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    timestamps()
  end

  relationships do
    belongs_to :human_account, Keyfleet.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :unique_provider_per_account, [:provider, :human_account_id]
    identity :unique_subject_per_provider, [:provider, :subject]
  end

  actions do
    create :upsert_verified do
      accept [
        :provider,
        :subject,
        :username,
        :display_name,
        :verified_at,
        :metadata,
        :human_account_id
      ]

      upsert? true
      upsert_identity :unique_provider_per_account
      upsert_fields [:subject, :username, :display_name, :verified_at, :metadata]
    end

    read :read_mine do
      filter expr(human_account_id == ^actor(:human_account_id))
      prepare build(sort: [provider: :asc])
    end

    read :for_account do
      argument :human_account_id, :integer, allow_nil?: false
      filter expr(human_account_id == ^arg(:human_account_id))
      prepare build(sort: [provider: :asc])
    end

    # The connections of these accounts that anyone may see beside their
    # addresses, on a fleet's Member List.
    read :shown_for_accounts do
      argument :human_account_ids, {:array, :integer},
        allow_nil?: false,
        constraints: [max_length: 100]

      filter expr(human_account_id in ^arg(:human_account_ids))
      prepare build(select: [:provider, :username, :human_account_id], sort: [provider: :asc])
    end

    read :by_provider_subject do
      get? true
      argument :provider, :atom, allow_nil?: false
      argument :subject, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider) and subject == ^arg(:subject))
    end

    destroy :remove_verified do
      accept []
      require_atomic? false
    end
  end

  policies do
    policy action([:upsert_verified, :for_account, :by_provider_subject, :remove_verified]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:shown_for_accounts) do
      authorize_if always()
    end

    policy action(:read_mine) do
      authorize_if actor_attribute_equals(:role, :human)
    end
  end
end
