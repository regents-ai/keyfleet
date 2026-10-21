defmodule Keyfleet.Graph.Pin do
  @moduledoc """
  Something a fleet's members keep at hand in their workspace: a notebook in
  its Docs (`place: :docs`, `target` the notebook's id) or a file or folder of
  its code in its Code (`place: :code`, `target` the path from the top of the
  repository). Every member sees the same pins, and any member pins; a pin is
  its pinner's, so only they unpin it.

  The title is what the page showed when it was pinned, so a pin still reads
  sensibly after the notebook or file it names is gone. Pinning what is
  already pinned keeps the one pin: the pinner's press takes the newer title,
  and anyone else's leaves the pin as its pinner made it.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # How many pins a place shows, newest first.
  @shown 100

  postgres do
    table "workspace_pins"
    repo(Keyfleet.Repo)
  end

  actions do
    defaults [:destroy]

    create :pin do
      accept [:fleet_id, :place, :target, :title, :folder?]
      change set_attribute(:human_account_id, actor(:human_account_id))
      upsert? true
      upsert_identity :one_per_target
      upsert_fields [:title]
      upsert_condition expr(human_account_id == ^actor(:human_account_id))
      return_skipped_upsert? true
      validate Keyfleet.Graph.Validations.KnownFleet
    end

    read :in_place do
      argument :fleet_id, :string, allow_nil?: false
      argument :place, :atom, allow_nil?: false, constraints: [one_of: [:docs, :code]]

      filter expr(fleet_id == ^arg(:fleet_id) and place == ^arg(:place))
      prepare build(sort: [inserted_at: :desc], limit: @shown)
    end
  end

  policies do
    policy action(:in_place) do
      authorize_if {Keyfleet.Access.Check, read: :workspace, scope: :fleet_id}
    end

    policy action_type([:create, :destroy]) do
      forbid_unless actor_attribute_equals(:role, :human)
      authorize_if {Keyfleet.Access.Check, write: :workspace, scope: :fleet_id}
    end

    policy action_type(:destroy) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :place, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:docs, :code]]

    attribute :target, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 1024, trim?: false]

    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 1024, trim?: false]

    attribute :folder?, :boolean, allow_nil?: false, default: false, public?: true
    attribute :human_account_id, :integer, allow_nil?: false, public?: true
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_per_target, [:fleet_id, :place, :target]
  end
end
