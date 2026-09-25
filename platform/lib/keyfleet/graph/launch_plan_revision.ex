defmodule Keyfleet.Graph.LaunchPlanRevision do
  @moduledoc """
  Every version a fleet's launch plans (its `launch_card` objects) have had,
  each under the digest a launch proposal carries for it; see
  `Keyfleet.Graph.LaunchPlanDigest`.

  The projector writes one row for each creation and each patch of a launch
  plan, an archive included, in the same page transaction as the object it
  changes. `data` is the plan as that version left it, exactly the fields the
  digest covers, and `seq` the place in the log of the change that made it.
  Like the other read tables, the rows hang off the fleet's cursor: removing
  the cursor removes them, and copying the log again writes them back the
  same.

  Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: Keyfleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @text [trim?: false]
  @digest [match: ~r/\A0x[0-9a-f]{64}\z/, trim?: false]

  postgres do
    table "graph_launch_plan_revisions"
    repo(Keyfleet.Repo)

    references do
      reference(:cursor, on_delete: :delete)
    end

    custom_indexes do
      index([:fleet_id, :object_id, :version], unique: true)
    end
  end

  actions do
    # What a proposal is matched against when it is asked whether it points
    # to a version of a plan.
    defaults [:read]

    # The plan versions that these digests name, as proposals carry them.
    read :for_digests do
      argument :fleet_id, :string, allow_nil?: false

      argument :digests, {:array, :string},
        allow_nil?: false,
        constraints: [items: @digest, max_length: 200]

      filter expr(fleet_id == ^arg(:fleet_id) and digest in ^arg(:digests))
    end

    # The given versions of the given plans, each named as
    # `%{object_id: id, version: v}`: to answer the digest of the version a
    # reader holds.
    read :current_for do
      argument :fleet_id, :string, allow_nil?: false

      argument :plans, {:array, :map},
        allow_nil?: false,
        constraints: [
          max_length: 200,
          items: [
            fields: [
              object_id: [type: :string, allow_nil?: false, constraints: @text],
              version: [type: :integer, allow_nil?: false, constraints: [min: 1]]
            ]
          ]
        ]

      filter expr(fleet_id == ^arg(:fleet_id))

      prepare fn query, _context ->
        plans = Ash.Query.get_argument(query, :plans)
        ids = Enum.map(plans, & &1.object_id)
        versions = Enum.map(plans, & &1.version)

        Ash.Query.filter(
          query,
          fragment(
            "(?, ?) IN (SELECT * FROM unnest(?::text[], ?::bigint[]))",
            object_id,
            version,
            ^ids,
            ^versions
          )
        )
      end
    end

    # A copy that is behind writes the same rows again before its cursor
    # check rolls its page back.
    create :project do
      public? false
      accept [:fleet_id, :digest, :object_id, :version, :seq, :data]
      upsert? true
      upsert_fields [:object_id, :version, :seq, :data]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:project) do
      authorize_if Keyfleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :digest, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: @digest

    attribute :object_id, :string, allow_nil?: false, public?: true, constraints: @text
    attribute :version, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :seq, Keyfleet.Graph.Seq, allow_nil?: false, public?: true
    attribute :data, :map, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :cursor, Keyfleet.Graph.Cursor do
      source_attribute :fleet_id
      destination_attribute :fleet_id
      define_attribute? false
    end
  end
end
