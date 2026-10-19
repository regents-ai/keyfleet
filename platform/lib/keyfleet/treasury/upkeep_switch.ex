defmodule Keyfleet.Treasury.UpkeepSwitch do
  @moduledoc """
  Whether the upkeep (`Keyfleet.Treasury.Upkeep`) is paused: one row, which
  an admin pauses and resumes, and `changed_by`, the account that last did.
  It is created paused, so after a release that brings it nothing is pressed
  until an admin resumes it. Only the site writes it; anyone may read it.
  """
  use Ash.Resource,
    domain: Keyfleet.Treasury,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "treasury_upkeep_switch"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:id, "treasury_upkeep_switch_one_row", check: "id = 1")
    end

    custom_statements do
      statement :paused_at_first do
        up("INSERT INTO keyfleet_app.treasury_upkeep_switch (id, paused) VALUES (1, true);")

        down("DELETE FROM keyfleet_app.treasury_upkeep_switch WHERE id = 1;")
      end
    end
  end

  actions do
    defaults [:read]

    read :the_switch do
      get? true
    end

    update :switch do
      public? false
      accept [:paused, :changed_by]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:switch) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :integer,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: 1]

    attribute :paused, :boolean, allow_nil?: false, public?: true
    attribute :changed_by, :integer, public?: true
    update_timestamp :updated_at, public?: true
  end
end
