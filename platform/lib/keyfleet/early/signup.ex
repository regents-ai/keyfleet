defmodule Keyfleet.Early.Signup do
  @moduledoc """
  One address on the early-access list.

  An address is stored trimmed and lowercased, with its host in ASCII form
  (`Keyfleet.Early.Signup.StoredEmail`), so each one is on the list once
  whatever its case or the spelling of its host, and one with a character
  inside it that shows as nothing or as a space is refused. Leaving an address
  that is already there changes nothing.
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

      # Nothing unseen inside the address once trimmed: no space of any kind,
      # no control character and nothing drawn as nothing, such as a
      # zero-width space.
      validate match(:email, ~r/\A[^\s\p{Cc}\p{DI}]+\z/u)

      change Keyfleet.Early.Signup.StoredEmail

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
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  attributes do
    uuid_primary_key :id

    # One @ with something on both sides, a dot in the domain and no spaces. The
    # pattern reads bytes (it has no `u` flag), so its lookahead holds an
    # address to 254 bytes: once trimmed as typed, and again as stored.
    attribute :email, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A(?=.{1,254}\z)[^@\s]+@[^@\s]+\.[^@\s]+\z/s]

    create_timestamp :inserted_at
  end
end
