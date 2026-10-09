defmodule Keyfleet.Accounts do
  @moduledoc "Human accounts, their verified sessions and linked social identities."

  use Ash.Domain

  resources do
    resource Keyfleet.Accounts.HumanAccount do
      define :get_by_privy_did, action: :by_privy_did, args: [:privy_did], not_found_error?: false
      define :points_account, action: :points_account, args: [:id]
      define :get_human_account, action: :read_self, args: [:id]
      define :accounts_holding_wallets, action: :holding_wallets, args: [:wallets]

      define :register_verified,
        action: :register_verified,
        args: [:privy_user_id, :wallet_address, :wallet_addresses]

      define :refresh_verified,
        action: :refresh_verified,
        args: [:wallet_address, :wallet_addresses]
    end

    resource Keyfleet.Accounts.SessionAuthority

    resource Keyfleet.Accounts.LinkedIdentity do
      define :upsert_linked_identity, action: :upsert_verified

      define :list_my_linked_identities, action: :read_mine
      define :list_linked_identities_for_account, action: :for_account, args: [:human_account_id]

      define :get_linked_identity_by_subject,
        action: :by_provider_subject,
        args: [:provider, :subject],
        not_found_error?: false

      define :remove_linked_identity, action: :remove_verified
    end
  end
end
