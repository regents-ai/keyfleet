defmodule KeyFleet.Keys.KeyAttachment do
  require Ash.Query
  @moduledoc "An immutable ownership epoch; a new epoch starts without an attached agent."
  use Ash.Resource,
    domain: KeyFleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "key_attachments"
    repo(KeyFleet.Repo)
    migration_defaults(observed_at: "fragment(\"(now() AT TIME ZONE 'utc')\")")

    check_constraints do
      check_constraint(:token_id, "key_attachments_positive_token", check: "token_id > 0")

      check_constraint(:ownership_epoch, "key_attachments_nonnegative_epoch",
        check: "ownership_epoch >= 0"
      )

      check_constraint(:block_number, "key_attachments_nonnegative_block",
        check: "block_number >= 0"
      )

      check_constraint(:log_index, "key_attachments_nonnegative_log", check: "log_index >= 0")

      check_constraint(:owner_wallet, "key_attachments_owner_shape",
        check: "owner_wallet ~ '^0x[0-9a-f]{40}$'"
      )

      check_constraint(:block_hash, "key_attachments_block_hash_shape",
        check: "block_hash ~ '^0x[0-9a-f]{64}$'"
      )

      check_constraint(:transaction_hash, "key_attachments_transaction_hash_shape",
        check: "transaction_hash ~ '^0x[0-9a-f]{64}$'"
      )
    end

    custom_statements do
      statement :immutable_epochs_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_key_epoch() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'key ownership epochs cannot be deleted' USING ERRCODE = '23514';
          END IF;
          IF ROW(NEW.id, NEW.fleet_id, NEW.token_id, NEW.ownership_epoch, NEW.owner_wallet,
                 NEW.block_number, NEW.block_hash, NEW.transaction_hash, NEW.log_index, NEW.observed_at)
             IS DISTINCT FROM
             ROW(OLD.id, OLD.fleet_id, OLD.token_id, OLD.ownership_epoch, OLD.owner_wallet,
                 OLD.block_number, OLD.block_hash, OLD.transaction_hash, OLD.log_index, OLD.observed_at) THEN
            RAISE EXCEPTION 'key ownership projection fields are immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_key_epoch();")
      end

      statement :immutable_epochs_trigger do
        up("""
        CREATE TRIGGER immutable_key_epochs BEFORE UPDATE OR DELETE ON keyfleet_app.key_attachments
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_key_epoch();
        """)

        down("""
        DROP TRIGGER immutable_key_epochs ON keyfleet_app.key_attachments;
        """)
      end
    end
  end

  actions do
    create :record_epoch do
      public? false
      transaction? true

      accept [
        :fleet_id,
        :token_id,
        :ownership_epoch,
        :owner_wallet,
        :block_number,
        :block_hash,
        :transaction_hash,
        :log_index
      ]

      upsert? true
      upsert_identity :unique_key_epoch
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
      change KeyFleet.Keys.Changes.VerifyReplay
    end

    read :history do
      argument :fleet_id, :string, allow_nil?: false

      argument :token_id, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 9_223_372_036_854_775_807]

      filter expr(fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id))

      prepare fn query, _context ->
        Ash.Query.before_action(query, fn query ->
          fleet_id = Ash.Query.get_argument(query, :fleet_id)
          token_id = Ash.Query.get_argument(query, :token_id)

          query
          |> Ash.Query.filter(fleet_id == ^fleet_id and token_id == ^token_id)
          |> Ash.Query.unset([:sort, :limit, :offset])
          |> Ash.Query.sort(ownership_epoch: :asc)
        end)
      end
    end

    read :current do
      argument :fleet_id, :string, allow_nil?: false

      argument :token_id, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 9_223_372_036_854_775_807]

      filter expr(fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id))

      prepare fn query, _context ->
        Ash.Query.before_action(query, fn query ->
          fleet_id = Ash.Query.get_argument(query, :fleet_id)
          token_id = Ash.Query.get_argument(query, :token_id)

          query
          |> Ash.Query.filter(fleet_id == ^fleet_id and token_id == ^token_id)
          |> Ash.Query.unset([:sort, :offset])
          |> Ash.Query.sort(ownership_epoch: :desc)
          |> Ash.Query.limit(1)
        end)
      end

      get? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record_epoch) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    for field <- [:ownership_epoch, :block_number, :log_index] do
      attribute field, :integer,
        allow_nil?: false,
        public?: true,
        constraints: [min: 0, max: 9_223_372_036_854_775_807]
    end

    attribute :owner_wallet, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    for field <- [:block_hash, :transaction_hash] do
      attribute field, :string,
        allow_nil?: false,
        public?: true,
        constraints: [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]
    end

    attribute :attached_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :observed_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false,
      public?: true
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end

    belongs_to :agent_profile, KeyFleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :unique_key_epoch, [:fleet_id, :token_id, :ownership_epoch]
    identity :unique_chain_event, [:transaction_hash, :log_index]
  end
end
