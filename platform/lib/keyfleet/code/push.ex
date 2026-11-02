defmodule Keyfleet.Code.Push do
  @moduledoc """
  One branch or tag a key's holder moved in one project's repository: which
  key, the wallet holding it, the branch or tag and the commit it now points
  at. The store accepted each one recorded (`KeyfleetWeb.Plugs.CodeGateway`).
  They are read as the code is, by the fleet's members (`Keyfleet.Access`,
  `:code`).
  """
  use Ash.Resource,
    domain: Keyfleet.Code,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "code_pushes"
    repo(Keyfleet.Repo)

    custom_indexes do
      index([:fleet_id, :project, :pushed_at])
    end
  end

  actions do
    create :record do
      accept [
        :fleet_id,
        :project,
        :token_id,
        :wallet,
        :ref,
        :head,
        :acting_agent_wallet,
        :beneficiary_privy_user_id,
        :agent_pairing_id
      ]

      emit Keyfleet.Code.Signals, :ref_pushed, dynamic?: true

      change {Keyfleet.Points.Changes.Announce,
              signals: Keyfleet.Code.Signals, signal: :ref_pushed, fields: [push_id: :id]}
    end

    # Every push to one project's repository, for its deletion.
    read :of_project do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and project == ^arg(:project))
    end

    destroy :forget do
      public? false
    end

    read :recent do
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      filter expr(fleet_id == ^arg(:fleet_id) and project == ^arg(:project))
      prepare build(sort: [pushed_at: :desc], limit: 10)
    end

    # The pushes `ids` names in one project's repository: who sent the
    # commits each one first brought (`Keyfleet.Code.Commit`).
    read :of_ids do
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      argument :ids, {:array, :uuid}, allow_nil?: false, constraints: [max_length: 100]

      filter expr(fleet_id == ^arg(:fleet_id) and project == ^arg(:project) and id in ^arg(:ids))
    end

    # The push with `id`, for the job that records the commits it brought.
    read :one do
      public? false
      get_by [:id]
    end

    # Every push to a branch, oldest first, for `Keyfleet.Code.Sent.backfill/0`.
    read :branches do
      public? false
      filter expr(fragment("starts_with(?, 'refs/heads/')", ref))
      prepare build(sort: [pushed_at: :asc])
    end

    # The newest tip of each branch before `before`, at most 100 of them: a
    # push brought the commits its tip reaches and none of these reach.
    read :tips_before do
      public? false
      argument :fleet_id, :string, allow_nil?: false
      argument :project, :string, allow_nil?: false
      argument :before, :utc_datetime_usec, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and project == ^arg(:project) and
                 pushed_at < ^arg(:before) and fragment("starts_with(?, 'refs/heads/')", ref)
             )

      prepare build(
                distinct: [:ref],
                distinct_sort: [pushed_at: :desc],
                limit: 100
              )
    end
  end

  policies do
    policy action([:recent, :of_ids]) do
      authorize_if {Keyfleet.Access.Check, read: :code, scope: :fleet_id}
    end

    policy action([:record, :of_project, :forget, :one, :branches, :tips_before]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :acting_agent_wallet, :string
    attribute :beneficiary_privy_user_id, :string, sensitive?: true
    attribute :agent_pairing_id, :uuid
    uuid_primary_key :id
    attribute :fleet_id, :string, allow_nil?: false, public?: true
    attribute :project, :string, allow_nil?: false, public?: true
    attribute :token_id, :integer, allow_nil?: false, public?: true
    attribute :wallet, :string, allow_nil?: false, public?: true
    attribute :ref, :string, allow_nil?: false, public?: true
    attribute :head, :string, allow_nil?: false, public?: true
    create_timestamp :pushed_at, public?: true
  end
end
