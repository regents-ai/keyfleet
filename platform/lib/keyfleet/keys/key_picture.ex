defmodule Keyfleet.Keys.KeyPicture do
  @moduledoc """
  A Key's card picture, kept on IPFS at `cid` (`Keyfleet.Lighthouse`), for
  the card seed it was drawn from (`Keyfleet.Keys.card_seed/2`). Only the
  picture job (`Keyfleet.Keys.DrawPicture`) records one, after Lighthouse has
  the picture; until then the key's metadata shows the Interim Keyfleet
  Access Pass.

  A picture is the Key's name and seed drawn, so it never changes: a Key
  whose seed an operator corrects after a reorg is shown by its new seed's
  picture, drawn afresh, and the old one is no longer asked for.

  Each picture also gets two small pictures: a close-up, kept at
  `close_up_cid`, the small square at the card's middle that the fleet's map
  shows (`Keyfleet.Keys.KeyArt.close_up/1`), and a small card, kept at
  `small_card_cid`, the whole card made small for a holder's cards
  (`Keyfleet.Keys.KeyArt.small_card/1`). A job per picture without one makes
  it (`MakeSmallPicture`), found every minute, so new cards and the cards
  drawn before it existed are covered the same way. Until it is made, the Key
  is shown by its number.
  """
  use Ash.Resource,
    domain: Keyfleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Keyfleet.Keys.KeyPicture.MakeSmallPicture

  postgres do
    table "key_pictures"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:token_id, "key_pictures_positive_token", check: "token_id > 0")
      check_constraint(:seed, "key_pictures_seed_shape", check: "seed ~ '^0x[0-9a-f]{64}$'")
    end
  end

  actions do
    defaults [:read]

    # Recording a picture again keeps the first record: a card's picture,
    # and so its address, never changes.
    create :record do
      public? false
      accept [:fleet_id, :token_id, :seed, :cid]
      upsert? true
      upsert_identity :unique_card_picture
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
    end

    # Every picture kept for these keys of the fleet, whichever seed each was
    # drawn from.
    read :of_keys do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_ids, {:array, :integer}, allow_nil?: false, constraints: [max_length: 100]
      filter expr(fleet_id == ^arg(:fleet_id) and token_id in ^arg(:token_ids))
      prepare build(select: [:token_id, :seed, :cid, :close_up_cid, :small_card_cid])
    end

    # The pictures the close-up job looks through, a page at a time.
    read :without_close_up do
      pagination keyset?: true, required?: false
      filter expr(is_nil(close_up_cid))
    end

    # The pictures the small-card job looks through, a page at a time.
    read :without_small_card do
      pagination keyset?: true, required?: false
      filter expr(is_nil(small_card_cid))
    end

    # Each reads the card back, makes its small picture and keeps it, outside
    # any transaction. The same card always gives the same small picture at
    # the same address, so running twice is safe.
    update :make_close_up do
      public? false
      transaction? false
      require_atomic? false
      change {MakeSmallPicture, kind: :close_up}
    end

    update :make_small_card do
      public? false
      transaction? false
      require_atomic? false
      change {MakeSmallPicture, kind: :small_card}
    end
  end

  oban do
    triggers do
      # Small pictures wait their turn behind new cards' drawings on the one queue.
      trigger :close_up do
        action :make_close_up
        read_action :without_close_up
        where expr(is_nil(close_up_cid))
        queue(:key_art)
        worker_priority(3)
        max_attempts(5)
        lock_for_update?(false)
        scheduler_module_name(Keyfleet.Keys.KeyPicture.Workers.CloseUpScheduler)
        worker_module_name(Keyfleet.Keys.KeyPicture.Workers.CloseUp)
      end

      trigger :small_card do
        action :make_small_card
        read_action :without_small_card
        where expr(is_nil(small_card_cid))
        queue(:key_art)
        worker_priority(3)
        max_attempts(5)
        lock_for_update?(false)
        scheduler_module_name(Keyfleet.Keys.KeyPicture.Workers.SmallCardScheduler)
        worker_module_name(Keyfleet.Keys.KeyPicture.Workers.SmallCard)
      end
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :seed, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false
      description "The seed the card's traits are drawn from."
    end

    attribute :cid, :string do
      allow_nil? false
      public? true
      description "The card's IPFS address, as Lighthouse answered it."
    end

    attribute :close_up_cid, :string do
      public? true
      description "The close-up's IPFS address, once it is made."
    end

    attribute :small_card_cid, :string do
      public? true
      description "The small card's IPFS address, once it is made."
    end

    create_timestamp :drawn_at, public?: true
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_card_picture, [:fleet_id, :token_id, :seed]
  end
end
