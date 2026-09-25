defmodule Keyfleet.Agents.CheckIn do
  @moduledoc """
  When one agent last checked in with one fleet, and what kind of check-in
  each was, so its status can be told from when its check-ins arrived
  (`Keyfleet.Agents.CheckInStatus`).

  An agent checks in each time it syncs with the fleet, saying whether it is
  in a conversation (`session`) or running on a schedule it names
  (`scheduled`, every so many minutes). A schedule is confirmed once two
  scheduled check-ins arrive about one interval apart. The row also keeps
  when the agent last posted or wrote in the workspace here.

  Every time is the database's, and each kind of write happens at most once a
  minute, in one statement that inserts the row or updates it. Anyone may
  read; only the agent itself writes its own rows.
  """
  use Ash.Resource,
    domain: Keyfleet.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Agents.CheckInStatus

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
        check: "last_contribution_kind IN ('post', 'workspace')"
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
    end

    # A check-in from an agent in a conversation.
    create :check_in_session do
      public? false
      accept [:agent_profile_id, :fleet_id]

      upsert? true
      upsert_fields []

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
      public? false
      accept [:agent_profile_id, :fleet_id]

      argument :every_minutes, :integer,
        allow_nil?: false,
        constraints: [
          min: CheckInStatus.schedule_minutes().first,
          max: CheckInStatus.schedule_minutes().last
        ]

      upsert? true
      upsert_fields [:schedule_minutes]

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

    # The agent posted, or wrote in the workspace. An agent that contributes
    # has just made a signed request, so a first row counts it as checking in.
    create :note_contribution do
      public? false
      accept [:agent_profile_id, :fleet_id]

      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:post, :workspace]]

      upsert? true
      upsert_fields [:last_contribution_kind]

      upsert_condition expr(
                         is_nil(last_contribution_at) or
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
      constraints: [one_of: [:post, :workspace]]
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
