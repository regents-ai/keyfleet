defmodule Keyfleet.Agents.CheckIn do
  @moduledoc """
  When one agent last checked in with one fleet, and what kind of check-in
  each was, so its status can be told from when its check-ins arrived
  (`Keyfleet.Agents.CheckInStatus`).

  An agent checks in each time it syncs with the fleet, saying whether it is
  in a conversation (`session`) or running on a schedule it names
  (`scheduled`, every so many minutes). A schedule is confirmed once two
  scheduled check-ins arrive about one interval apart, and the row counts
  every scheduled check-in, the times the agent came back on its own. The row
  also keeps when the agent last did something here, and what: a post, a task
  taken or handed in, a review, another workspace write, a notebook edit or a push.

  Every time is the database's, and each kind of write happens at most once a
  minute (a contribution of a new kind at once), in one statement that inserts the row or updates it. Anyone may
  read; only the agent itself writes its own rows.
  """
  use Ash.Resource,
    domain: Keyfleet.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Agents.CheckInStatus

  @contribution_kinds [:post, :task, :submit, :review, :workspace, :notebook, :code]

  postgres do
    table "agent_check_ins"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:schedule_minutes, "agent_check_ins_schedule_minutes",
        check: "schedule_minutes BETWEEN 10 AND 1440"
      )

      # Only a declared schedule can be confirmed.
      check_constraint(:schedule_confirmed_at, "agent_check_ins_confirmed_schedule",
        check: "schedule_confirmed_at IS NULL OR schedule_minutes IS NOT NULL"
      )

      check_constraint(:last_contribution_kind, "agent_check_ins_contribution_kind",
        check:
          "last_contribution_kind IN ('post', 'task', 'submit', 'review', 'workspace', 'notebook', 'code')"
      )

      # A contribution has both its time and its kind, or neither.
      check_constraint(:last_contribution_at, "agent_check_ins_contribution_whole",
        check: "(last_contribution_at IS NULL) = (last_contribution_kind IS NULL)"
      )
    end
  end

  actions do
    read :read do
      primary? true
    end

    # These agents' check-ins with the fleet, to show beside the keys they run.
    read :in_fleet do
      argument :fleet_id, :string, allow_nil?: false

      argument :agent_profile_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [max_length: 100]

      filter expr(fleet_id == ^arg(:fleet_id) and agent_profile_id in ^arg(:agent_profile_ids))
      prepare build(load: [:last_seen_at])
    end

    # A check-in from an agent in a conversation.
    create :check_in_session do
      change Keyfleet.Agents.Changes.RecordAuthority
      change {RegentAgents.RequirePairing, repo: Keyfleet.Repo}
      public? false
      accept [:agent_profile_id, :fleet_id]

      upsert? true
      upsert_fields [:acting_agent_wallet, :beneficiary_privy_user_id, :agent_pairing_id]

      upsert_condition expr(
                         is_nil(last_session_at) or
                           last_session_at <
                             fragment(
                               "(statement_timestamp() AT TIME ZONE 'utc') - make_interval(secs => ?)",
                               ^CheckInStatus.spacing_seconds()
                             )
                       )

      return_skipped_upsert? true

      change atomic_set(
               :last_check_in_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )

      change atomic_update(
               :last_check_in_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )

      change atomic_set(
               :last_session_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )

      change atomic_update(
               :last_session_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )
    end

    # A check-in an agent makes on its own schedule, every `every_minutes`.
    create :check_in_scheduled do
      change Keyfleet.Agents.Changes.RecordAuthority
      change {RegentAgents.RequirePairing, repo: Keyfleet.Repo}
      public? false
      accept [:agent_profile_id, :fleet_id]

      argument :every_minutes, :integer,
        allow_nil?: false,
        constraints: [
          min: CheckInStatus.schedule_minutes().first,
          max: CheckInStatus.schedule_minutes().last
        ]

      upsert? true

      upsert_fields [
        :schedule_minutes,
        :acting_agent_wallet,
        :beneficiary_privy_user_id,
        :agent_pairing_id
      ]

      upsert_condition expr(
                         is_nil(last_scheduled_at) or
                           last_scheduled_at <
                             fragment(
                               "(statement_timestamp() AT TIME ZONE 'utc') - make_interval(secs => ?)",
                               ^CheckInStatus.spacing_seconds()
                             )
                       )

      return_skipped_upsert? true

      change set_attribute(:schedule_minutes, arg(:every_minutes))
      change Keyfleet.Agents.Changes.ScheduledCheckIn, only_when_valid?: true
    end

    # The agent did something here (`@contribution_kinds`): something new is
    # written at once, a repeat of the last kind at most once a minute. An
    # agent that contributes has just made a signed request, so a first row
    # counts it as checking in.
    create :note_contribution do
      change Keyfleet.Agents.Changes.RecordAuthority
      change {RegentAgents.RequirePairing, repo: Keyfleet.Repo}
      public? false
      accept [:agent_profile_id, :fleet_id]

      argument :kind, :atom, allow_nil?: false, constraints: [one_of: @contribution_kinds]

      upsert? true

      upsert_fields [
        :last_contribution_kind,
        :acting_agent_wallet,
        :beneficiary_privy_user_id,
        :agent_pairing_id
      ]

      upsert_condition expr(
                         is_nil(last_contribution_at) or
                           last_contribution_kind != ^arg(:kind) or
                           last_contribution_at <
                             fragment(
                               "(statement_timestamp() AT TIME ZONE 'utc') - make_interval(secs => ?)",
                               ^CheckInStatus.spacing_seconds()
                             )
                       )

      return_skipped_upsert? true

      change set_attribute(:last_contribution_kind, arg(:kind))

      change atomic_set(
               :last_check_in_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )

      change atomic_set(
               :last_contribution_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )

      change atomic_update(
               :last_contribution_at,
               expr(fragment("(statement_timestamp() AT TIME ZONE 'utc')"))
             )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:check_in_session, :check_in_scheduled, :note_contribution]) do
      authorize_if Keyfleet.Agents.Checks.OwnProfile
    end
  end

  attributes do
    attribute :acting_agent_wallet, :string, writable?: false
    attribute :beneficiary_privy_user_id, :string, writable?: false, sensitive?: true
    attribute :agent_pairing_id, :uuid, writable?: false

    attribute :last_check_in_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_session_at, :utc_datetime_usec, public?: true
    attribute :last_scheduled_at, :utc_datetime_usec, public?: true
    # The scheduled check-in the next one's gap is measured from.
    attribute :counted_scheduled_at, :utc_datetime_usec, public?: true

    attribute :schedule_minutes, :integer,
      public?: true,
      constraints: [
        min: CheckInStatus.schedule_minutes().first,
        max: CheckInStatus.schedule_minutes().last
      ]

    attribute :schedule_confirmed_at, :utc_datetime_usec, public?: true
    attribute :last_contribution_at, :utc_datetime_usec, public?: true

    attribute :last_contribution_kind, :atom,
      public?: true,
      constraints: [one_of: @contribution_kinds]

    # Every scheduled check-in it has made here.
    attribute :scheduled_check_ins, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      constraints: [min: 0]
  end

  calculations do
    # When the agent was last seen in the fleet: its last check-in, or its last
    # contribution if that came later.
    calculate :last_seen_at,
              :utc_datetime_usec,
              expr(
                if is_nil(last_contribution_at) or last_contribution_at < last_check_in_at do
                  last_check_in_at
                else
                  last_contribution_at
                end
              )
  end

  relationships do
    belongs_to :agent_profile, Keyfleet.Agents.AgentProfile do
      primary_key? true
      allow_nil? false
      public? true
    end

    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end
