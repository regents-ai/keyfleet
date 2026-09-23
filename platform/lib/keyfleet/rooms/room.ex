defmodule KeyFleet.Rooms.Room do
  @moduledoc """
  A room with a stable identity within its fleet.

  Every fleet has its three core rooms. Each Fibonacci fleet also has one room
  for every level that has sold a key, which only the system opens
  (`KeyFleet.Rooms.ensure_level_rooms/1`), and its
  members may open topic rooms: either for the whole fleet or following one
  level's rule for who may post. Nobody renames or removes a room.
  """
  use Ash.Resource,
    domain: KeyFleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @core_slugs ["general", "planning", "work"]
  @slug ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  # Addresses a member may not take: a core room's, and any level room's.
  @not_core_slug Regex.compile!("\\A(?!(?:#{Enum.join(@core_slugs, "|")})\\z)")
  @not_level_slug ~r/\A(?!level-[0-9]+\z)/
  # Names a member may not take: a core room's, and any level room's, in any
  # case. Names are trimmed before this is checked.
  @not_kept_name Regex.compile!(
                   "\\A(?!(?:#{Enum.join(@core_slugs, "|")}|level [0-9]+)\\z)",
                   "i"
                 )
  # No control characters, line breaks or characters that turn text around,
  # the same set the workspace refuses (graph_host/src/keyfleet_graph/protocol.py).
  @plain_name ~r/\A[^\x{0}-\x{1f}\x{7f}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]*\z/u

  postgres do
    table "rooms"
    repo(KeyFleet.Repo)

    check_constraints do
      # `KeyFleet.Rooms.Sequence` moves this column with a statement of its own,
      # so the floor is kept where that statement cannot step over it.
      check_constraint(:head_seq, "rooms_nonnegative_head", check: "head_seq >= 0")

      check_constraint(:level, "rooms_level_range",
        check: "level IS NULL OR level BETWEEN 1 AND 20"
      )

      # A level room is named after its level, so the fleet's one-name-per-room
      # rule is also its one-room-per-level rule. Core rooms follow no level,
      # and only a level room takes a level's name.
      check_constraint(:kind, "rooms_kind_shape",
        check: """
        (kind = 'core' AND level IS NULL AND slug !~ '^level-[0-9]+$')
        OR (kind = 'level' AND level IS NOT NULL AND slug = 'level-' || level)
        OR (kind = 'topic' AND slug !~ '^level-[0-9]+$')
        """
      )
    end
  end

  actions do
    read :for_fleet do
      argument :fleet_id, :string, allow_nil?: false
      validate KeyFleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [position: :asc, level: :asc_nils_first, slug: :asc])
    end

    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and slug == ^arg(:slug))
      get? true
    end

    create :bootstrap do
      public? false
      accept [:fleet_id, :slug, :name]
      validate one_of(:slug, @core_slugs)
      change set_attribute(:kind, :core)
      upsert? true
      upsert_identity :unique_slug_per_fleet
      upsert_fields [:name]
    end

    create :create_topic do
      accept [:fleet_id, :slug, :name, :level]

      validate match(:slug, @slug), message: "must be lowercase letters, digits and single dashes"
      validate match(:slug, @not_core_slug), message: "is the name of a core room"
      validate match(:slug, @not_level_slug), message: "is kept for a level's own room"
      validate match(:name, @not_kept_name), message: "is kept for one of the fleet's own rooms"

      validate match(:name, @plain_name),
        message: "must not hold control characters, line breaks or direction changes"

      validate KeyFleet.Graph.Validations.KnownFleet
      # A fleet's levels are only asked after once the fleet is known to exist.
      validate KeyFleet.Rooms.Validations.FleetLevel, only_when_valid?: true

      change set_attribute(:kind, :topic)
      change KeyFleet.Rooms.Changes.LimitTopicRooms

      # Everyone watching the fleet's rooms sees the new one.
      change after_transaction(fn
               _changeset, {:ok, room}, _context ->
                 KeyFleet.Rooms.rooms_opened(room.fleet_id)
                 {:ok, room}

               _changeset, result, _context ->
                 result
             end)
    end
  end

  policies do
    policy action([:for_fleet, :in_fleet]) do
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if KeyFleet.Checks.SystemActor
    end

    policy action(:create_topic) do
      authorize_if KeyFleet.Rooms.Checks.RoomPoster
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :slug, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 63, trim?: false]

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 80]

    # Which of the three kinds of room this is: one of the fleet's own three,
    # a level's room, or a topic a member opened.
    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:core, :level, :topic]]

    # The Fibonacci level whose rule decides who posts here, or nil when
    # anyone holding one of the fleet's keys may.
    attribute :level, :integer, public?: true, constraints: [min: 1, max: 20]

    # How many posts this room has taken, which is also the place the newest one
    # holds. Only `KeyFleet.Rooms.Sequence` moves it.
    attribute :head_seq, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: 0,
      constraints: [min: 0]
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  calculations do
    # Core rooms first, then level rooms, then topics.
    calculate :position,
              :integer,
              expr(
                cond do
                  kind == :core -> 0
                  kind == :level -> 1
                  true -> 2
                end
              )
  end

  identities do
    # A taken address is the slug's problem, whoever asks.
    identity :unique_slug_per_fleet, [:fleet_id, :slug],
      field_names: [:slug],
      message: "is already in use in this fleet"
  end
end
