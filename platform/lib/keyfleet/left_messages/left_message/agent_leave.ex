defmodule Keyfleet.LeftMessages.LeftMessage.AgentLeave do
  @moduledoc """
  An agent's message, the same on every surface: `%{receipt:
  LeftMessage.receipt/1, replayed: boolean}`.

  The agent's `operation_id` is spent once: the message keeps it, and one
  agent's messages never share one (the `one_per_operation` identity). A reuse
  with the same topic, text and reply_to answers the receipt of the message it
  left (`replayed: true`) and leaves nothing; a reuse with any other is refused
  as `idempotency_conflict`. Of two calls with one key at once, the second is
  refused by the identity, finds the first's message, and answers as a reuse.

  Every caller passes the client key as `context: %{client_key: key}`, which
  the message's allowances count (`LimitMessages`).
  """

  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Actors.{Agent, System}
  alias Keyfleet.Agents
  alias Keyfleet.LeftMessages.{LeftMessage, Refused}

  @impl true
  def run(input, _opts, %{actor: %Agent{} = actor}) do
    %{operation_id: key} = arguments = input.arguments

    case Agents.get_my_profile(actor: actor) do
      {:ok, nil} -> {:error, Refused.exception(code: "profile_not_found")}
      {:ok, profile} -> leave_once(arguments, profile, key, actor, input.context)
      {:error, error} -> {:error, error}
    end
  end

  defp leave_once(arguments, profile, key, actor, context) do
    case left(profile, key) do
      {:ok, nil} -> leave(arguments, profile, key, actor, context)
      {:ok, message} -> reuse(message, arguments)
      {:error, error} -> {:error, error}
    end
  end

  defp leave(arguments, profile, key, actor, context) do
    LeftMessage
    |> Ash.Changeset.for_create(:leave, Map.take(arguments, [:topic, :body, :reply_to]),
      actor: actor,
      context: %{client_key: Map.fetch!(context, :client_key)}
    )
    |> Ash.Changeset.force_change_attribute(:operation_id, key)
    |> Ash.create()
    |> case do
      {:ok, message} -> {:ok, %{receipt: LeftMessage.receipt(message), replayed: false}}
      {:error, error} -> answer_spent(error, arguments, profile, key)
    end
  end

  # The key was spent by a call that saved while this one was on its way.
  defp answer_spent(error, arguments, profile, key) do
    with true <- key_spent?(error),
         {:ok, %LeftMessage{} = message} <- left(profile, key) do
      reuse(message, arguments)
    else
      _not_spent -> {:error, error}
    end
  end

  defp key_spent?(%Ash.Error.Invalid{errors: errors}),
    do:
      Enum.any?(
        errors,
        &match?(%Ash.Error.Changes.InvalidAttribute{field: :agent_profile_id}, &1)
      )

  defp key_spent?(_error), do: false

  defp left(profile, key) do
    Ash.read_one(
      Ash.Query.for_read(
        LeftMessage,
        :by_operation,
        %{agent_profile_id: profile.id, operation_id: key},
        actor: %System{}
      )
    )
  end

  defp reuse(message, arguments) do
    if {message.topic, message.body, message.reply_to} ==
         {arguments.topic, arguments.body, arguments[:reply_to]},
       do: {:ok, %{receipt: LeftMessage.receipt(message), replayed: true}},
       else: {:error, Refused.exception(code: "idempotency_conflict")}
  end
end
