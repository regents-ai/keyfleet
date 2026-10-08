defmodule Keyfleet.Polls.Vote do
  @moduledoc """
  A Key's one vote in a round: the move it chose, how sure it is (0 to 1, if
  it says) and a short reason. `counted` says whether the vote decides
  anything: every vote does in a `:poll` session, only the delegate's Key's in
  a `:delegate` one, where the rest are suggestions.

  A Key votes once in a round, whichever of its agents sends it: sending the
  same move again answers the vote it already has, and a different move is
  refused. Votes are never changed or removed.
  """
  use Ash.Resource,
    otp_app: :keyfleet,
    domain: Keyfleet.Polls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @bigint 9_223_372_036_854_775_807

  postgres do
    table "poll_votes"
    repo(Keyfleet.Repo)

    references do
      reference(:round, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:token_id, "poll_votes_token_id", check: "token_id > 0")

      check_constraint(:confidence, "poll_votes_confidence",
        check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
      )

      check_constraint(:wallet, "poll_votes_wallet_shape", check: "wallet ~ '^0x[0-9a-f]{40}$'")
    end

    custom_statements do
      statement :poll_votes_function do
        up("""
        CREATE FUNCTION keyfleet_app.protect_poll_vote() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'poll votes cannot be changed or deleted' USING ERRCODE = '23514';
        END;
        $$;
        """)

        down("DROP FUNCTION keyfleet_app.protect_poll_vote();")
      end

      statement :poll_votes_trigger do
        up("""
        CREATE TRIGGER protect_poll_votes BEFORE UPDATE OR DELETE ON keyfleet_app.poll_votes
        FOR EACH ROW EXECUTE FUNCTION keyfleet_app.protect_poll_vote();
        """)

        down("DROP TRIGGER protect_poll_votes ON keyfleet_app.poll_votes;")
      end
    end
  end

  actions do
    create :cast do
      accept [:action, :confidence, :reason]
      transaction? true

      argument :fleet_id, :string, allow_nil?: false
      argument :session_id, :uuid, allow_nil?: false
      argument :number, :integer, allow_nil?: false, constraints: [min: 1, max: @bigint]

      # The Key's own vote settles a repeat: the database hands back the vote
      # it already has.
      upsert? true
      upsert_identity :unique_vote
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      change Keyfleet.Polls.Changes.CastVote
    end

    read :in_round do
      public? false
      argument :round_id, :uuid, allow_nil?: false
      filter expr(round_id == ^arg(:round_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :of_key do
      public? false
      argument :round_id, :uuid, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      get? true
      filter expr(round_id == ^arg(:round_id) and token_id == ^arg(:token_id))
    end
  end

  policies do
    policy action(:cast) do
      authorize_if {Keyfleet.Polls.Checks.Standing, role: :member}
    end

    policy action([:in_round, :of_key]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1, max: @bigint]

    attribute :wallet, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/, trim?: false]

    attribute :action, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 64, trim?: false]

    attribute :confidence, :float, public?: true, constraints: [min: 0.0, max: 1.0]

    attribute :reason, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :counted, :boolean, allow_nil?: false, public?: true, writable?: false

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :round, Keyfleet.Polls.Round do
      attribute_writable? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_vote, [:round_id, :token_id]
  end

  @doc "The vote as agents read it."
  def to_map(vote, round_number) do
    %{
      round: round_number,
      key: vote.token_id,
      action: vote.action,
      confidence: vote.confidence,
      reason: vote.reason,
      counted: vote.counted,
      at: vote.inserted_at
    }
  end
end
