defmodule Keyfleet.Keys.KeyPicture do
  @moduledoc """
  A reveal's card picture, kept on IPFS at `cid` (`Keyfleet.Lighthouse`).
  Only the picture job (`Keyfleet.Keys.DrawPicture`) records one, after
  Lighthouse has the picture; until then the key's metadata shows the Interim
  Keyfleet Access Pass.

  A picture belongs to one reveal, since the card is drawn from its seed:
  when an operator removes the reveal after a reorg, its picture record goes
  with it, and the reveal read again is drawn again from its own seed.
  """
  use Ash.Resource,
    domain: Keyfleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "key_pictures"
    repo(Keyfleet.Repo)

    references do
      reference(:reveal, on_delete: :delete)
    end
  end

  actions do
    defaults [:read]

    # Recording a picture again keeps the first record: a reveal's picture,
    # and so its address, never changes.
    create :record do
      public? false
      accept [:reveal_id, :cid]
      upsert? true
      upsert_identity :unique_reveal_picture
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :cid, :string do
      allow_nil? false
      public? true
      description "The card's IPFS address, as Lighthouse answered it."
    end

    create_timestamp :drawn_at, public?: true
  end

  relationships do
    belongs_to :reveal, Keyfleet.Keys.KeyReveal do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_reveal_picture, [:reveal_id]
  end
end
