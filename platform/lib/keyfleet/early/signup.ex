defmodule Keyfleet.Early.Signup do
  @moduledoc """
  One address on the early-access list.

  An address is stored trimmed and lowercased, so each one is on the list once
  whatever its case. Leaving an address that is already there changes nothing.
  """
  use Ash.Resource,
    domain: Keyfleet.Early,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "early_signups"
    repo(Keyfleet.Repo)
  end

  actions do
    defaults [:read]

    create :sign_up do
      accept [:email]

      # An address that failed its check is nil here and stays refused.
      change fn changeset, _context ->
        Ash.Changeset.update_change(changeset, :email, fn
          email when is_binary(email) -> String.downcase(email)
          nil -> nil
        end)
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields []
    end
  end

  policies do
    # Anyone may leave an address; the page limits how often one client can.
    policy action(:sign_up) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  attributes do
    uuid_primary_key :id

    # One @ with something on both sides, a dot in the domain and no spaces. The
    # pattern reads bytes (it has no `u` flag), so its lookahead holds an
    # address to 254 bytes.
    attribute :email, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A(?=.{1,254}\z)[^@\s]+@[^@\s]+\.[^@\s]+\z/s]

    create_timestamp :inserted_at
  end
end
