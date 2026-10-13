defmodule Keyfleet.Rooms.WallRemoval do
  @moduledoc """
  A post taken off a Key's wall by the person holding that Key.

  The post itself stays as it was written: a post is never changed or
  deleted. From its removal on, the wall leaves it out for everyone who reads
  it, on the site and through the agent API. A removal names only the post;
  the wall it is on and the wallet holding that Key are read from the post
  (`Keyfleet.Rooms.Changes.OffItsWall`), so nobody takes a post off a wall it
  isn't on. A removal is never undone, and removing a post twice keeps the
  one removal.
  """
  use Ash.Resource,
    domain: Keyfleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "wall_removals"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:token_id, "wall_removals_positive_token", check: "token_id > 0")

      check_constraint(:holder_wallet, "wall_removals_holder_shape",
        check: "holder_wallet ~ '^0x[0-9a-f]{40}$'"
      )
    end

    custom_indexes do
      # How many posts are off one Key's wall.
      index(["fleet_id", "token_id"], name: "wall_removals_wall_index")
    end
  end

  actions do
    defaults [:read]

    create :remove do
      accept [:message_id]
      upsert? true
      upsert_identity :one_per_post
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
      change Keyfleet.Rooms.Changes.OffItsWall
    end

    # The posts off one Key's wall.
    read :of_wall do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false, constraints: [min: 1, max: @max_bigint]
      filter expr(fleet_id == ^arg(:fleet_id) and token_id == ^arg(:token_id))
    end
  end

  # Delivered after the transaction commits, as `%Phoenix.Socket.Broadcast{}`
  # with the event "wall_removed" and `%{fleet_id, token_id, message_id}`, on
  # both of the fleet's room topics (`Keyfleet.Rooms.topic/2`), since anyone
  # reads a Key's wall: every page with the wall open drops the post.
  pub_sub do
    module Phoenix.PubSub
    name Keyfleet.PubSub
    prefix "fleet"
    broadcast_type :phoenix_broadcast
    filter &(!Ash.Resource.get_metadata(&1.data, :upsert_skipped))

    transform &%{
                fleet_id: &1.data.fleet_id,
                token_id: &1.data.token_id,
                message_id: &1.data.message_id
              }

    publish :remove, [:fleet_id, "rooms", "members"], event: "wall_removed"
    publish :remove, [:fleet_id, "rooms"], event: "wall_removed"
  end

  # Anyone may know a post is off a wall, as anyone reads the wall. Only the
  # person holding the Key now takes a post off its wall; while the fleet's
  # key ownership is not fresh, nobody does.
  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:remove) do
      forbid_unless actor_attribute_equals(:role, :human)
      authorize_if {Keyfleet.Dms.Checks.KeyHolder, keys: [:token_id]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @max_bigint],
      description: "The Key whose wall the post is off."

    attribute :holder_wallet, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "The wallet holding the Key when the post came off."

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      attribute_writable? false
      allow_nil? false
      public? true
    end

    belongs_to :message, Keyfleet.Rooms.Message do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_per_post, [:message_id]
  end
end
