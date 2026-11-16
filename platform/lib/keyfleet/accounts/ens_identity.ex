defmodule Keyfleet.Accounts.EnsIdentity do
  @moduledoc """
  The ENS name and picture Ethereum mainnet publishes for an account's wallet.

  This is a copy of public chain state, not identity evidence: the account's
  own row keeps the verified Privy identity and wallet. Each sign-in asks again
  (`:request_lookup`), and one job, queued in the same transaction, reads the
  chain outside any transaction (`LookUp`). A wallet with no verified name is
  stored with none; a lookup that keeps failing leaves the last name standing.

  `wallet_address` is the wallet the row was read for, so an account whose
  wallet has since changed is never shown the old wallet's name.

  A lookup is pending, done or failed (`lookup_state`), and its moves are
  declared in the `state_machine` block: asking makes it pending from any
  stage, and only a pending lookup becomes done or failed. The database holds
  no other stage.

  Lookups run only while the server has an Ethereum endpoint
  (`ETHEREUM_READ_RPC_URL`).
  """

  use Ash.Resource,
    domain: Keyfleet.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban, AshStateMachine]

  alias Keyfleet.Accounts.EnsIdentity.LookUp

  postgres do
    table "account_ens_identities"
    repo(Keyfleet.Repo)
    # Every row is written by asking, which names its stage, so the column
    # keeps no default of its own.
    migration_defaults(lookup_state: "nil")

    check_constraints do
      check_constraint(:lookup_state, "account_ens_identities_lookup_state",
        check: "lookup_state IN ('pending', 'done', 'failed')"
      )
    end
  end

  state_machine do
    initial_states([:pending])
    state_attribute(:lookup_state)

    transitions do
      transition(:request_lookup, from: :*, to: :pending)
      transition(:look_up, from: :pending, to: :done)
      transition(:lookup_failed, from: :pending, to: :failed)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :wallet_address, :string, allow_nil?: false
    attribute :ens_name, :string, public?: true
    attribute :ens_avatar_url, :string, public?: true

    attribute :lookup_state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :done, :failed]]

    timestamps()
  end

  relationships do
    belongs_to :human_account, Keyfleet.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :unique_human_account, [:human_account_id]
  end

  actions do
    defaults [:read]

    create :request_lookup do
      accept [:human_account_id, :wallet_address]
      change transition_state(:pending)
      change run_oban_trigger(:look_up)
      upsert? true
      upsert_identity :unique_human_account
      upsert_fields [:wallet_address, :lookup_state, :updated_at]
    end

    update :look_up do
      transaction? false
      require_atomic? false
      change transition_state(:done)
      change LookUp
    end

    update :lookup_failed do
      change transition_state(:failed)
    end
  end

  oban do
    triggers do
      # Every sign-in queues its own job, so there is no sweep to find missed ones.
      trigger :look_up do
        action :look_up
        where expr(lookup_state == :pending)
        queue(:ens)
        max_attempts(3)
        on_error(:lookup_failed)
        lock_for_update?(false)
        scheduler_cron(false)
        worker_module_name(Keyfleet.Accounts.EnsIdentity.Workers.LookUp)
      end
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action(:request_lookup) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Chain state anyone can read for themselves, so the account it belongs to
    # is what protects it, not this row.
    policy action(:read) do
      authorize_if always()
    end
  end

  # Asking, a finished lookup and one that gave up each reach the open pages of
  # the account they belong to, which read the account again.
  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "ens_identity"
    broadcast_type :broadcast
    transform & &1.data

    publish :request_lookup, [:human_account_id]
    publish :look_up, [:human_account_id]
    publish :lookup_failed, [:human_account_id]
  end

  @doc "The topic a finished lookup for `human_account_id` is published on."
  def topic(human_account_id), do: "ens_identity:#{human_account_id}"

  @doc "Whether the server can read Ethereum mainnet."
  def looking_up?, do: not is_nil(rpc_url())

  @doc "The Ethereum mainnet endpoint lookups read from."
  def rpc_url, do: Application.get_env(:keyfleet, :ethereum_read_rpc_url)
end
