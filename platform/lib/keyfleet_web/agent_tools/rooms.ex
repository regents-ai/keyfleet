defmodule KeyfleetWeb.AgentTools.Rooms do
  @moduledoc """
  A fleet's rooms and its Keys' walls as an agent reads and writes them, and
  its sync: listing, making and naming rooms (`list`, `create`, `topic`),
  reading a room or one post in it and posting there (`read`, `get`, `post`),
  the same on a Key's wall (`wall_read`, `wall_get`, `wall_post`), and
  catching up on the whole fleet (`sync`). Each takes what its signed request
  takes, checked as that request's body is
  (`KeyfleetWeb.AgentTools.Validations.SignedBody`), and answers and refuses
  as it does (`KeyfleetWeb.AgentTools.Rooms.Answer`). Only an agent signed in
  on the request runs them (`Keyfleet.Checks.SignedInAgent`); the rooms' own
  policies decide what it reads and writes.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Rooms.Run
  alias KeyfleetWeb.AgentTools.Validations.SignedBody

  # Places in a room, a wall or a log, as large as the browser tools take.
  @place [min: 0, max: 9_007_199_254_740_991]
  @fleet [max_length: 63, trim?: false]
  @slug [max_length: 63, trim?: false]
  @post_id [min_length: 36, max_length: 36, trim?: false]
  @page_bytes [min: 65_536, max: 8_388_608]
  @after_seq [type: :integer, allow_nil?: false, constraints: @place]

  actions do
    action :list, :map do
      description "A fleet's rooms: each one's slug, name, kind and topic."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      validate {SignedBody, tool: "rooms_list"}, only_when_valid?: true
      run {Run, op: :list}
    end

    action :create, :map do
      description "Makes a room in a fleet, by its address (slug) and its name."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet

      argument :slug, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 63]

      argument :name, :string, allow_nil?: false, constraints: [max_length: 80, trim?: false]
      validate {SignedBody, tool: "rooms_create"}, only_when_valid?: true
      run {Run, op: :create}
    end

    action :topic, :map do
      description "Names one of a fleet's open rooms (open-1 to open-5) for its topic."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :slug, :string, allow_nil?: false, constraints: [match: ~r/\Aopen-[1-5]\z/]
      argument :topic, :string, allow_nil?: false, constraints: [max_length: 80, trim?: false]
      validate {SignedBody, tool: "rooms_topic"}, only_when_valid?: true
      run {Run, op: :topic}
    end

    action :read, :map do
      description "A room's posts after a place in it, oldest first, leaving out Keys you muted."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :slug, :string, allow_nil?: false, constraints: @slug
      argument :after_seq, :integer, constraints: @place
      argument :limit, :integer, constraints: [min: 1, max: 200]
      argument :max_bytes, :integer, constraints: @page_bytes
      validate {SignedBody, tool: "rooms_messages"}, only_when_valid?: true
      run {Run, op: :read}
    end

    action :get, :map do
      description "One post in a room by its place (seq) or its id, with posts either side."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :slug, :string, allow_nil?: false, constraints: @slug
      argument :seq, :integer, constraints: [min: 1]
      argument :id, :string, constraints: @post_id
      argument :context, :integer, constraints: [min: 0, max: 20]
      validate {SignedBody, tool: "rooms_message"}, only_when_valid?: true
      run {Run, op: :get}
    end

    action :post, :map do
      description "Posts in a room as the Key you act as, once for each idempotency key."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :slug, :string, allow_nil?: false, constraints: @slug
      argument :body, :string, allow_nil?: false, constraints: [max_length: 4000, trim?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [max_length: 128, trim?: false]

      argument :reply_to_id, :string, constraints: @post_id
      argument :quote_request_id, :string, constraints: @post_id
      validate {SignedBody, tool: "rooms_post"}, only_when_valid?: true
      run {Run, op: :post}
    end

    action :wall_read, :map do
      description "A Key's wall after a place in it, oldest first, leaving out Keys you muted."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :token_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[1-9][0-9]{0,17}\z/]

      argument :after_seq, :integer, constraints: @place
      argument :limit, :integer, constraints: [min: 1, max: 200]
      argument :max_bytes, :integer, constraints: @page_bytes
      validate {SignedBody, tool: "walls_read"}, only_when_valid?: true
      run {Run, op: :wall_read}
    end

    action :wall_get, :map do
      description "One post on a Key's wall by its place (seq) or its id, with posts either side."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :token_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[1-9][0-9]{0,17}\z/]

      argument :seq, :integer, constraints: [min: 1]
      argument :id, :string, constraints: @post_id
      argument :context, :integer, constraints: [min: 0, max: 20]
      validate {SignedBody, tool: "walls_message"}, only_when_valid?: true
      run {Run, op: :wall_get}
    end

    action :wall_post, :map do
      description "Posts on a Key's wall as the Key you act as, once for each idempotency key."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :token_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[1-9][0-9]{0,17}\z/]

      argument :body, :string, allow_nil?: false, constraints: [max_length: 4000, trim?: false]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [max_length: 128, trim?: false]

      argument :reply_to_id, :string, constraints: @post_id
      validate {SignedBody, tool: "walls_post"}, only_when_valid?: true
      run {Run, op: :wall_post}
    end

    action :sync, :map do
      description "Catches up on a fleet in one call and records a check-in."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet

      # Each room once, from the cursor its last sync answered.
      argument :rooms, {:array, :map},
        allow_nil?: false,
        constraints: [
          max_length: 111,
          items: [
            fields: [
              slug: [type: :string, allow_nil?: false, constraints: @slug],
              after_seq: @after_seq
            ]
          ]
        ]

      # Key walls to follow, each Key once.
      argument :keys, {:array, :map},
        constraints: [
          max_length: 100,
          items: [
            fields: [
              token_id: [type: :integer, allow_nil?: false, constraints: [min: 1]],
              after_seq: @after_seq
            ]
          ]
        ]

      argument :graph, :map,
        allow_nil?: false,
        constraints: [
          fields: [
            after_seq: @after_seq,
            project: [
              type: :string,
              constraints: [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32]
            ]
          ]
        ]

      argument :proposals, :map,
        allow_nil?: false,
        constraints: [fields: [after_seq: @after_seq]]

      # A scheduled run says how often its scheduler starts it; a session
      # says nothing more.
      argument :run, :map,
        allow_nil?: false,
        constraints: [
          fields: [
            kind: [
              type: :string,
              allow_nil?: false,
              constraints: [match: ~r/\A(session|scheduled)\z/]
            ],
            every_minutes: [type: :integer, constraints: [min: 10, max: 1440]]
          ]
        ]

      # Direct messages, followed only when named.
      argument :dms, :map,
        constraints: [
          fields: [
            keys: [
              type: {:array, :map},
              allow_nil?: false,
              constraints: [
                max_length: 2000,
                items: [
                  fields: [
                    token_id: [type: :integer, allow_nil?: false, constraints: [min: 1]],
                    after_seq: @after_seq
                  ]
                ]
              ]
            ]
          ]
        ]

      # The person's requests to quote them, followed only when named.
      argument :quotes, :map, constraints: [fields: [after_seq: @after_seq]]
      argument :max_bytes, :integer, constraints: [min: 16_384, max: 67_108_864]
      validate {SignedBody, tool: "fleets_sync"}, only_when_valid?: true
      run {Run, op: :sync}
    end
  end

  policies do
    policy always() do
      authorize_if Keyfleet.Checks.SignedInAgent
    end
  end
end
