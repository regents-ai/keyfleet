defmodule Keyfleet.Agents.AgentProfile do
  @moduledoc "A stable product identity for one verified SIWA wallet."
  use Ash.Resource,
    domain: Keyfleet.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_profiles"
    repo(Keyfleet.Repo)
  end

  actions do
    create :ensure_profile do
      accept [
        :name,
        :avatar,
        :declared_harness,
        :proficiencies,
        :interests,
        :service_ideas,
        :current_status
      ]

      change set_attribute(:wallet_address, actor(:wallet_address))
      upsert? true
      upsert_identity :unique_wallet
      upsert_fields []
      return_skipped_upsert? true
    end

    read :get_my_profile do
      get? true
      filter expr(wallet_address == ^actor(:wallet_address))
    end

    # The identity an agent presents to the key owners it works for: its name,
    # what it runs on, and what it says it is doing and since when. Nothing
    # else leaves here.
    read :public_profile do
      prepare build(select: [:id, :name, :declared_harness, :current_status, :status_updated_at])
    end

    # The agents running at least one of the fleet's keys right now, by name,
    # with how many of its keys each runs and the lowest-numbered one.
    # Requested, ended and earlier owners' pairings don't count.
    read :here_in_fleet do
      argument :fleet_id, :string, allow_nil?: false

      filter expr(exists(pairings, fleet_id == ^arg(:fleet_id) and effective?))

      prepare fn query, _context ->
        fleet_id = Ash.Query.get_argument(query, :fleet_id)

        query
        |> Ash.Query.select([:id, :name, :declared_harness, :wallet_address])
        |> Ash.Query.load(keys_run: %{fleet_id: fleet_id}, first_key: %{fleet_id: fleet_id})
        |> Ash.Query.sort(name: :asc, id: :asc)
      end
    end

    update :edit_my_profile do
      atomic_upgrade_with :get_my_profile

      accept [
        :name,
        :avatar,
        :declared_harness,
        :proficiencies,
        :interests,
        :service_ideas,
        :current_status
      ]

      change Keyfleet.Agents.Changes.TrackProfileActivity
    end
  end

  policies do
    policy action([:public_profile, :here_in_fleet]) do
      authorize_if always()
    end

    policy action([:ensure_profile, :get_my_profile, :edit_my_profile]) do
      authorize_if Keyfleet.Checks.AgentActor
    end

    policy action_type([:read, :update]) do
      authorize_if action([:public_profile, :here_in_fleet])
      authorize_if expr(wallet_address == ^actor(:wallet_address))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :wallet_address, :string do
      allow_nil? false
      writable? false
      constraints match: ~r/\A0x[0-9a-f]{40}\z/, max_length: 42
    end

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :avatar, :string, public?: true, constraints: [max_length: 2048]

    attribute :declared_harness, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    for field <- [:proficiencies, :interests, :service_ideas] do
      attribute field, {:array, :string} do
        allow_nil? false
        public? true
        default []
        constraints max_length: 50, items: [min_length: 1, max_length: 2000, allow_empty?: false]
      end
    end

    attribute :current_status, :string,
      allow_nil?: false,
      public?: true,
      default: "",
      constraints: [max_length: 2000, allow_empty?: true]

    attribute :status_updated_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      default: &DateTime.utc_now/0

    attribute :last_activity_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      default: &DateTime.utc_now/0
  end

  relationships do
    has_many :pairings, Keyfleet.Keys.KeyPairing do
      destination_attribute :agent_profile_id
      public? false
    end
  end

  calculations do
    # How many of the fleet's keys this agent runs right now.
    calculate :keys_run,
              :integer,
              expr(
                count(pairings,
                  query: [filter: expr(fleet_id == ^arg(:fleet_id) and effective?)]
                )
              ) do
      argument :fleet_id, :string, allow_nil?: false
      public? true
    end

    # The lowest-numbered of the fleet's keys this agent runs right now.
    calculate :first_key,
              :integer,
              expr(
                min(pairings,
                  field: :token_id,
                  query: [filter: expr(fleet_id == ^arg(:fleet_id) and effective?)]
                )
              ) do
      argument :fleet_id, :string, allow_nil?: false
      public? true
    end
  end

  identities do
    identity :unique_wallet, [:wallet_address]
  end
end
