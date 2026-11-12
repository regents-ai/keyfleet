defmodule Keyfleet.LeftMessages.LeftMessage do
  @moduledoc """
  One message left for the site's team under a `topic` the site names, such
  as `agents`: its text, where the sender wants an answer (`reply_to`) and who
  left it. A signed-in person or a signed agent with a profile leaves one, a
  few an hour at most, from each of them and from each network (`:message`
  and `:message_address` in `Keyfleet.Limits`, `LimitMessages`). The sender is
  the actor, never an input (`SetSender`). Only the site's admins read them
  (`RegentAgents.Checks.Admin`); the sender gets a receipt, `receipt/1`, and
  never reads them back.

  An agent's message carries the `operation_id` it chose, spent once per
  agent (`AgentLeave`).
  """

  use Ash.Resource,
    domain: Keyfleet.LeftMessages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.LeftMessages.LeftMessage.{AgentLeave, LimitMessages, SetSender}

  @topic [max_length: 40, match: ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/]
  @shown_text "Use letters, numbers and marks you can see."

  postgres do
    table "left_messages"
    repo(Keyfleet.Repo)

    references do
      reference(:human_account, on_delete: :restrict)
      reference(:agent_profile, on_delete: :restrict)
    end

    custom_indexes do
      index([:inserted_at, :id])
    end

    check_constraints do
      check_constraint(:human_account_id, "has_sender",
        check: "human_account_id IS NOT NULL OR agent_profile_id IS NOT NULL",
        message: "has a sender"
      )
    end
  end

  attributes do
    uuid_primary_key :id
    # A short name the site gives the place it was left from, such as agents.
    attribute :topic, :string, allow_nil?: false, public?: true, constraints: @topic
    attribute :body, :string, allow_nil?: false, public?: true, constraints: [max_length: 2000]
    # Where the sender wants an answer, in their own words.
    attribute :reply_to, :string, public?: true, constraints: [max_length: 200]
    # The sender's name when they left it: the person's name or short wallet,
    # or the agent's profile name.
    attribute :sender_name, :string, allow_nil?: false, public?: true
    # The agent's own id for this message, which a retry sends again.
    attribute :operation_id, :uuid, writable?: false
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    # The person it was left by or for: a signed-in person, or a paired agent's.
    belongs_to :human_account, Keyfleet.Accounts.HumanAccount do
      attribute_type :integer
      attribute_writable? false
      public? true
    end

    # The agent that left it.
    belongs_to :agent_profile, Keyfleet.Agents.AgentProfile do
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :one_per_operation, [:agent_profile_id, :operation_id]
  end

  actions do
    defaults [:read]

    # The team's inbox, newest first, a page at a time.
    read :newest do
      prepare build(sort: [inserted_at: :desc, id: :desc])
      pagination keyset?: true, default_limit: 50
    end

    # An agent's earlier message under its operation_id (`AgentLeave`).
    read :by_operation do
      get? true
      argument :agent_profile_id, :uuid, allow_nil?: false
      argument :operation_id, :uuid, allow_nil?: false

      filter expr(
               agent_profile_id == ^arg(:agent_profile_id) and
                 operation_id == ^arg(:operation_id)
             )
    end

    create :leave do
      accept [:topic, :body, :reply_to]
      change SetSender
      validate match(:body, RegentFormat.Text.pattern()), message: @shown_text
      validate match(:reply_to, RegentFormat.Name.pattern()), message: @shown_text
      change LimitMessages
    end

    # An agent's message, its operation_id spent once, as every surface
    # answers it (`AgentLeave`, called from a function, so a change to it
    # recompiles nothing here).
    action :agent_leave, :map do
      argument :topic, :string,
        allow_nil?: false,
        constraints: @topic,
        description:
          "The topic the site gives, such as agents: lowercase letters, numbers and hyphens, up to 40."

      argument :body, :string,
        allow_nil?: false,
        constraints: [max_length: 2000],
        description: "The message, 1 to 2,000 characters."

      argument :reply_to, :string,
        constraints: [max_length: 200],
        description:
          "Where you want an answer, up to 200 characters, such as an email address, a room or a profile. Leave it out for none."

      argument :operation_id, :uuid,
        allow_nil?: false,
        description:
          "A UUID you make for this message. Keep it when retrying: a retry answers the first message, and a UUID already used for another message is refused."

      run fn input, context -> AgentLeave.run(input, [], context) end
    end
  end

  policies do
    policy action(:leave) do
      authorize_if actor_attribute_equals(:role, :human)
      authorize_if actor_attribute_equals(:role, :agent)
    end

    policy action(:agent_leave) do
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # The site's admins on their team page; the site itself when it answers a
    # retried message with its receipt (`AgentLeave`).
    policy action_type(:read) do
      authorize_if RegentAgents.Checks.Admin
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  @doc "What the sender is told once a message is left: its id, topic and time."
  def receipt(message),
    do: %{id: message.id, topic: message.topic, inserted_at: message.inserted_at}
end
