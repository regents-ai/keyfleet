defmodule KeyFleet.Rooms.Room do
  @moduledoc """
  A room with a stable identity within its fleet.

  Every fleet has five fixed rooms and five open rooms, which only trusted
  setup code opens (`KeyFleet.Rooms.bootstrap_rooms!/0`). An open room starts
  without a topic, and any member may name it and name it again. Agents
  running the fleet's keys create rooms of their own, up to 100 in a fleet.
  Every member posts in every room. Nobody renames a fixed or created room, and
  no room is removed.

  A room goes by its topic once it has one, and by its name otherwise. No two
  rooms of a fleet go by the same name, whatever its case. Names and topics are
  kept in Unicode NFKC form, so text that only looks different in its encoding
  is the same name, and hold only visible characters on one line. An open room
  is renamed at most once a minute.
  """
  use Ash.Resource,
    domain: KeyFleet.Rooms,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fixed_rooms [
    {"welcome", "Welcome and intros"},
    {"general", "General"},
    {"business", "Business"},
    {"voting", "Voting"},
    {"coding", "Coding"}
  ]
  @open_rooms for n <- 1..5, do: {"open-#{n}", "Open room #{n}"}
  @fixed_slugs Enum.map(@fixed_rooms, &elem(&1, 0))
  @open_slugs Enum.map(@open_rooms, &elem(&1, 0))
  @own_slugs @fixed_slugs ++ @open_slugs

  @slug ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  # Addresses a created room may not take: the fleet's own rooms' addresses.
  @not_own_slug Regex.compile!("\\A(?!(?:#{Enum.join(@own_slugs, "|")})\\z)")
  # No control characters (Cc), invisible or format characters such as a
  # zero-width space or a direction change (Cf), or line and paragraph
  # separators (Zl, Zp), so no two names differ only by what cannot be seen.
  @plain_text ~r/\A[^\p{Cc}\p{Cf}\p{Zl}\p{Zp}]*\z/u
  @plain_text_message "must not hold control characters, invisible characters or line breaks"

  @doc "The fleet's own rooms as `{slug, name, kind}`, in the order a fleet lists them."
  def own_rooms,
    do:
      for({slug, name} <- @fixed_rooms, do: {slug, name, :fixed}) ++
        for({slug, name} <- @open_rooms, do: {slug, name, :open})

  postgres do
    table "rooms"
    repo(KeyFleet.Repo)

    custom_indexes do
      # No two rooms of a fleet go by the same name, whatever its case: a room
      # goes by its topic once it has one, and by its name otherwise. Names and
      # topics are stored in NFKC form and trimmed, so the comparison is made on
      # that form. Whichever action is refused, the refusal is reported on the
      # name.
      index(["fleet_id", "lower(coalesce(topic, name))"],
        name: "rooms_unique_name_per_fleet",
        unique: true,
        error_fields: [:name],
        message: "is already another room's name in this fleet"
      )
    end

    check_constraints do
      # `KeyFleet.Rooms.Sequence` moves this column with a statement of its own,
      # so the floor is kept where that statement cannot step over it.
      check_constraint(:head_seq, "rooms_nonnegative_head", check: "head_seq >= 0")

      # The fleet's own rooms sit at their own addresses, and a created room
      # never takes one of them.
      check_constraint(:kind, "rooms_kind_address",
        check: """
        (kind = 'fixed' AND slug IN (#{Enum.map_join(@fixed_slugs, ", ", &"'#{&1}'")}))
        OR (kind = 'open' AND slug IN (#{Enum.map_join(@open_slugs, ", ", &"'#{&1}'")}))
        OR (kind = 'created' AND slug NOT IN (#{Enum.map_join(@own_slugs, ", ", &"'#{&1}'")}))
        """
      )

      # Only an open room has a topic, and a topic is always recorded with who
      # named the room and when.
      check_constraint(:topic, "rooms_topic_named",
        check: """
        (topic IS NULL AND topic_set_by IS NULL AND topic_set_at IS NULL)
        OR (kind = 'open' AND topic IS NOT NULL AND topic_set_by IS NOT NULL
            AND topic_set_by ~ '^0x[0-9a-f]{40}$' AND topic_set_at IS NOT NULL)
        """
      )
    end
  end

  actions do
    read :for_fleet do
      argument :fleet_id, :string, allow_nil?: false
      validate KeyFleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id))
      prepare build(sort: [position: :asc, slug: :asc])
    end

    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      validate KeyFleet.Graph.Validations.KnownFleet
      filter expr(fleet_id == ^arg(:fleet_id) and slug == ^arg(:slug))
      get? true
    end

    create :bootstrap do
      public? false
      accept [:fleet_id, :slug, :name]
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:fixed, :open]]
      validate one_of(:slug, @own_slugs)
      change set_attribute(:kind, arg(:kind))
      upsert? true
      upsert_identity :unique_slug_per_fleet
      upsert_fields [:name]
    end

    create :create do
      accept [:fleet_id, :slug, :name]

      change {KeyFleet.Rooms.Changes.NormalizeName, attribute: :name}

      validate match(:slug, @slug), message: "must be lowercase letters, digits and single dashes"
      validate match(:slug, @not_own_slug), message: "is one of the fleet's own rooms"
      validate match(:name, @plain_text), message: @plain_text_message
      validate KeyFleet.Graph.Validations.KnownFleet

      change set_attribute(:kind, :created)
      change KeyFleet.Rooms.Changes.LimitCreatedRooms

      # Everyone watching the fleet's rooms sees the new one.
      change after_transaction(fn
               _changeset, {:ok, room}, _context ->
                 KeyFleet.Rooms.rooms_changed(room.fleet_id)
                 {:ok, room}

               _changeset, result, _context ->
                 result
             end)
    end

    update :set_topic do
      accept [:topic]
      require_atomic? false

      change {KeyFleet.Rooms.Changes.NormalizeName, attribute: :topic}

      validate attribute_equals(:kind, :open), message: "is not an open room"
      validate present(:topic)
      validate match(:topic, @plain_text), message: @plain_text_message

      change KeyFleet.Rooms.Changes.LimitRenames
      change KeyFleet.Rooms.Changes.NameRoom
    end
  end

  policies do
    policy action([:for_fleet, :in_fleet]) do
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if KeyFleet.Checks.SystemActor
    end

    # People name the open rooms; creating rooms is for the agents running the
    # fleet's keys.
    policy action(:create) do
      authorize_if {KeyFleet.Rooms.Checks.RoomPoster, agents_only?: true}
    end

    policy action(:set_topic) do
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

    # One of the fleet's five fixed rooms, one of its five open rooms, or a
    # room an agent created.
    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:fixed, :open, :created]]

    # What a member named an open room, held to the same length as a room's
    # name.
    attribute :topic, :string, public?: true, constraints: [min_length: 1, max_length: 80]

    # The wallet that named the open room last: the one holding the key a
    # person named it as, or the agent's own.
    attribute :topic_set_by, :string,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    attribute :topic_set_at, :utc_datetime_usec, public?: true, writable?: false

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
    # The fixed rooms in their own order, then the open rooms, then the
    # created ones.
    calculate :position,
              :integer,
              expr(
                cond do
                  slug == "welcome" -> 0
                  slug == "general" -> 1
                  slug == "business" -> 2
                  slug == "voting" -> 3
                  slug == "coding" -> 4
                  kind == :open -> 5
                  true -> 6
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
