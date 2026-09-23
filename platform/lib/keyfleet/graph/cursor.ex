defmodule KeyFleet.Graph.Cursor do
  @moduledoc """
  How far one fleet's graph log has been copied into the read tables, and
  from which run of that log.

  The read tables hang off this row: removing it removes every event, object
  and relation copied for the fleet, and the copy then starts again from the
  beginning of the log. Only the projector writes here; anyone may read.
  """
  use Ash.Resource,
    domain: KeyFleet.Graph,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "graph_cursors"
    repo(KeyFleet.Repo)

    check_constraints do
      check_constraint(:applied_seq, "graph_cursors_nonnegative_applied_seq",
        check: "applied_seq >= 0"
      )
    end
  end

  actions do
    defaults [:read]

    create :start do
      public? false
      accept [:fleet_id, :run_id]
      change set_attribute(:applied_seq, 0)
    end

    # Moves the cursor on only from where this copy found it. When another
    # copy has moved it meanwhile, this one fails, and the page it copied
    # rolls back with it.
    update :advance do
      public? false
      accept [:applied_seq]
      require_attributes [:applied_seq]
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(applied_seq == ^changeset.data.applied_seq))
      end
    end

    destroy :forget do
      public? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:start, :advance, :forget]) do
      authorize_if KeyFleet.Checks.SystemActor
    end
  end

  attributes do
    attribute :run_id, :string, allow_nil?: false, public?: true, constraints: [trim?: false]

    # The last place in the log copied, counting every event, including the
    # ones the read tables leave out.
    attribute :applied_seq, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
  end

  relationships do
    belongs_to :fleet, KeyFleet.Fleets.Fleet do
      attribute_type :string
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end
