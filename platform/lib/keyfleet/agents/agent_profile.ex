defmodule Keyfleet.Agents.AgentProfile do
  @moduledoc "A stable product identity for one verified SIWA wallet."
  use Ash.Resource,
    domain: Keyfleet.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "agent_profiles"
    repo(Keyfleet.Repo)
  end

  actions do
    create :ensure_profile do
      accept [
        :name,
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

    # A profile by its id, only ever the actor's own (see the policies);
    # `get_and_lock_for_update` re-reads the profile a picture change locks
    # with it.
    read :read do
      primary? true
    end

    read :get_my_profile do
      get? true
      filter expr(wallet_address == ^actor(:wallet_address))
    end

    # The identity an agent presents to the key owners it works for: its name,
    # its picture, what it runs on, and what it says it is doing and since
    # when. Nothing else leaves here.
    read :public_profile do
      prepare build(
                select: [:id, :name, :declared_harness, :current_status, :status_updated_at],
                load: [:avatar_src]
              )
    end

    # The agents holding an active shard of one of the fleet's keys, with
    # that key and their check-ins with the fleet: the most recent check-in
    # first, then those that haven't checked in, by name.
    read :here_in_fleet do
      argument :fleet_id, :string, allow_nil?: false

      filter expr(exists(shards, fleet_id == ^arg(:fleet_id) and active?))

      prepare fn query, _context ->
        fleet_id = Ash.Query.get_argument(query, :fleet_id)

        query
        |> Ash.Query.select([:id, :name, :declared_harness, :wallet_address])
        |> Ash.Query.load(
          avatar_src: %{},
          key: %{fleet_id: fleet_id},
          check_ins: Ash.Query.filter(Keyfleet.Agents.CheckIn, fleet_id == ^fleet_id)
        )
        |> Ash.Query.sort(
          last_check_in_at: {%{fleet_id: fleet_id}, :desc_nils_last},
          name: :asc,
          id: :asc
        )
      end
    end

    # The agents holding an active shard in any of these fleets, by the same
    # rule as `:here_in_fleet`, each once however many fleets it holds shards
    # in.
    read :here_in_fleets do
      argument :fleet_ids, {:array, :string}, allow_nil?: false, constraints: [max_length: 100]
      filter expr(exists(shards, fleet_id in ^arg(:fleet_ids) and active?))
    end

    # The agents behind some wallets, by name, to say who made a change the
    # workspace records under an agent's wallet.
    read :by_wallets do
      argument :wallets, {:array, :string}, allow_nil?: false, constraints: [max_length: 100]
      filter expr(wallet_address in ^arg(:wallets))
      prepare build(select: [:id, :wallet_address, :name])
    end

    update :edit_my_profile do
      atomic_upgrade_with :get_my_profile

      accept [
        :name,
        :declared_harness,
        :proficiencies,
        :interests,
        :service_ideas,
        :current_status
      ]

      change Keyfleet.Agents.Changes.TrackProfileActivity
    end

    # The agent's own picture, already stored in the bucket under `avatar_key`
    # (`Keyfleet.Agents.store_avatar/4`). The picture it replaces is deleted
    # after the change commits.
    update :set_avatar do
      require_atomic? false
      accept [:avatar_key]
      require_attributes [:avatar_key]
      change get_and_lock_for_update()
      change Keyfleet.Agents.Changes.ReplaceAvatar
    end

    update :remove_avatar do
      require_atomic? false
      change get_and_lock_for_update()
      change set_attribute(:avatar_key, nil)
      change Keyfleet.Agents.Changes.ReplaceAvatar
    end
  end

  policies do
    policy action([:public_profile, :here_in_fleet, :here_in_fleets, :by_wallets]) do
      authorize_if always()
    end

    policy action([
             :read,
             :ensure_profile,
             :get_my_profile,
             :edit_my_profile,
             :set_avatar,
             :remove_avatar
           ]) do
      authorize_if Keyfleet.Checks.AgentActor
    end

    policy action_type([:read, :update]) do
      authorize_if action([:public_profile, :here_in_fleet, :here_in_fleets, :by_wallets])
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

    # Where the agent's own picture is kept in the bucket, or nil when it has
    # none: `agent-avatars/<profile id>/<upload id>.<png|jpg|webp>`
    # (`Keyfleet.Agents.Avatar`).
    attribute :avatar_key, :string,
      public?: true,
      constraints: [
        max_length: 200,
        match:
          ~r"\Aagent-avatars/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(png|jpg|webp)\z"
      ]

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
    # Every shard record naming this agent's wallet, in every fleet.
    has_many :shards, Keyfleet.Keys.ShardEvent do
      source_attribute :wallet_address
      destination_attribute :wallet
      public? false
    end

    has_many :check_ins, Keyfleet.Agents.CheckIn do
      public? false
    end
  end

  calculations do
    # The picture a page shows beside the agent's name.
    calculate :avatar_src, :string, Keyfleet.Agents.Calculations.AvatarSrc do
      public? true
    end

    # When this agent last checked in with the fleet.
    calculate :last_check_in_at,
              :utc_datetime_usec,
              expr(
                first(check_ins,
                  field: :last_check_in_at,
                  query: [filter: expr(fleet_id == ^arg(:fleet_id))]
                )
              ) do
      argument :fleet_id, :string, allow_nil?: false
      public? true
    end

    # The key of the active shard this agent holds in the fleet, if any: a
    # wallet holds one shard in a fleet at a time.
    calculate :key,
              :integer,
              expr(
                min(shards,
                  field: :token_id,
                  query: [filter: expr(fleet_id == ^arg(:fleet_id) and active?)]
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
