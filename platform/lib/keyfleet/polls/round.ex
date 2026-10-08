defmodule Keyfleet.Polls.Round do
  @moduledoc """
  One decision a session takes together: what the agents see
  (`observation`), the moves they choose from (`actions`), the deadline, and
  the Keys with a vote (`roster`, the Keys seated when it opened).

  `decision_ref` names the outside decision the round answers, such as a
  match and its turn, and a session answers each one once. A session has at
  most one round open at a time. A round closes once (`Keyfleet.Polls.Tally`
  gives its result), and a closed round never changes.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Polls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807

  postgres do
    table "poll_rounds"
    repo(Keyfleet.Repo)

    references do
      reference(:session, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:number, "poll_rounds_number", check: "number > 0")
      check_constraint(:status, "poll_rounds_status", check: "status IN ('open', 'closed')")

      check_constraint(:outcome, "poll_rounds_closed_with_outcome",
        check:
          "(status = 'open' AND outcome IS NULL AND closed_at IS NULL) OR " <>
            "(status = 'closed' AND outcome IN ('decided', 'no_votes') AND closed_at IS NOT NULL)"
      )
    end

    custom_indexes do
      # One round open at a time in a session.
      index(["session_id"],
        name: "poll_rounds_one_open_index",
        unique: true,
        where: "status = 'open'"
      )
    end

    custom_statements do
      statement :closed_poll_rounds_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_poll_round() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'poll rounds cannot be deleted' USING ERRCODE = '23514';
          END IF;
          IF OLD.status = 'closed' THEN
            RAISE EXCEPTION 'a closed poll round cannot change' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_poll_round();")
      end

      statement :closed_poll_rounds_trigger do
        up("""
        CREATE TRIGGER protect_poll_rounds BEFORE UPDATE OR DELETE ON keyfleet_app.poll_rounds
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_poll_round();
        """)

        down("DROP TRIGGER protect_poll_rounds ON keyfleet_app.poll_rounds;")
      end
    end
  end

  actions do
    create :open do
      accept [:decision_ref, :observation, :actions]
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :session_id, :uuid, allow_nil?: false
      argument :deadline_seconds, :integer, allow_nil?: false, constraints: [min: 1, max: 600]

      validate Keyfleet.Polls.Validations.Decision
      change Keyfleet.Polls.Changes.OpenRound
    end

    update :close do
      accept []
      require_atomic? false
      transaction? true

      change Keyfleet.Polls.Changes.CloseRound
    end

    read :read do
      primary? true
      public? false
    end

    read :by_id do
      public? false
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :in_session do
      public? false
      argument :session_id, :uuid, allow_nil?: false
      argument :number, :integer, allow_nil?: false
      get? true
      filter expr(session_id == ^arg(:session_id) and number == ^arg(:number))
    end
  end

  policies do
    policy action(:open) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :delegate}
    end

    policy action([:close, :read, :by_id, :in_session]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :number, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

    attribute :decision_ref, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 128, trim?: false]

    # Shared only with the session's seated Keys.
    attribute :observation, :map, allow_nil?: false, public?: true

    attribute :actions, {:array, Keyfleet.Polls.Action},
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 2, max_length: 32]

    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true, writable?: false

    attribute :roster, {:array, :integer},
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [items: [min: 1, max: @bigint]]

    attribute :status, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      writable?: false,
      constraints: [one_of: [:open, :closed]]

    # Set as the round closes, with everything below.
    attribute :outcome, :atom,
      public?: true,
      writable?: false,
      constraints: [one_of: [:decided, :no_votes]]

    attribute :winner, :string, public?: true, writable?: false
    attribute :votes_cast, :integer, public?: true, writable?: false
    attribute :tally, :map, public?: true, writable?: false
    attribute :closed_at, :utc_datetime_usec, public?: true, writable?: false

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :session, Keyfleet.Polls.Session do
      attribute_writable? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_number, [:session_id, :number]
    # A repeated outside decision is decision_ref's problem.
    identity :unique_decision, [:session_id, :decision_ref],
      field_names: [:decision_ref],
      message: "already had a round in this session"
  end

  @doc "The round as agents read it, in its log lines and in answers."
  def to_map(round) do
    %{
      number: round.number,
      decision_ref: round.decision_ref,
      observation: round.observation,
      actions: Enum.map(round.actions, &%{id: &1.id, label: &1.label}),
      deadline_at: round.deadline_at,
      roster: round.roster,
      status: round.status,
      outcome: round.outcome,
      winner: round.winner,
      votes_cast: round.votes_cast,
      tally: round.tally,
      closed_at: round.closed_at
    }
  end
end
