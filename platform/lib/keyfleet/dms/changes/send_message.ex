defmodule Keyfleet.Dms.Changes.SendMessage do
  @moduledoc """
  Writes one direct message from Key `from_token_id` to Key `to_token_id` of
  the same fleet, opening the pair's conversation with the first message, or
  hands back the message this Key already sent under the same send key.

  The fleet's direct messages are written one at a time, so the order the
  database gives them (`seq`) is the order they become readable, and a reader
  carrying on from the last one it saw never misses one. Whether the sender
  still holds the Key is read once more inside that turn: a Key that changed
  hands since the policy looked leaves nothing to write as.

  The message keeps the wallet it came from: the person's wallet holding the
  Key, or the agent's own. An agent writing it, for itself or for the person it
  is paired with, is kept as `via_agent`; an agent with no profile yet has
  nothing to write as.

  The same send key with the same words hands back the first message; with
  anything different it is a mistake and is refused, so a sender that never
  heard the answer can simply ask again.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.System
  alias Keyfleet.Dms
  alias Keyfleet.Rooms.Errors.NoAgentProfileError
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError
  alias Keyfleet.Rooms.Errors.SendConflictError

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.before_action(&write(&1, actor))
    |> Ash.Changeset.after_action(&confirm/2)
  end

  defp write(changeset, actor) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    from = Ash.Changeset.get_argument(changeset, :from_token_id)
    lock_fleet!(fleet_id)

    with {:ok, sender} <- sender(actor, fleet_id, from),
         {:ok, via_agent_id} <- via_agent(actor) do
      to = Ash.Changeset.get_argument(changeset, :to_token_id)

      conversation =
        Dms.open_conversation!(
          %{fleet_id: fleet_id, key_a: min(from, to), key_b: max(from, to)},
          actor: %System{}
        )

      Ash.Changeset.force_change_attributes(changeset, %{
        fleet_id: fleet_id,
        conversation_id: conversation.id,
        from_token_id: from,
        to_token_id: to,
        body: Ash.Changeset.get_argument(changeset, :body),
        parts: Ash.Changeset.get_argument(changeset, :parts),
        author_wallet: sender.wallet,
        via_agent_id: via_agent_id,
        idempotency_key: Ash.Changeset.get_argument(changeset, :idempotency_key)
      })
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # Every direct message of a fleet waits here for the one before it to commit.
  defp lock_fleet!(fleet_id) do
    Keyfleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["dms", fleet_id])
    ])
  end

  defp sender(actor, fleet_id, from) do
    case Enum.find(Keyfleet.Keys.held_keys(actor, fleet_id), &(&1.token_id == from)) do
      nil -> {:error, NoKeyToWriteAsError.exception(fleet_id: fleet_id)}
      sender -> {:ok, sender}
    end
  end

  defp via_agent(%Agent{} = actor) do
    case Keyfleet.Agents.get_my_profile!(actor: actor) do
      nil -> {:error, NoAgentProfileError.exception([])}
      profile -> {:ok, profile.id}
    end
  end

  defp via_agent(_person), do: {:ok, nil}

  # The database settles which message a send key names. Whatever comes back
  # must be the message these words were meant to make, to the Key they were
  # meant for.
  defp confirm(changeset, message) do
    if message.to_token_id == Ash.Changeset.get_argument(changeset, :to_token_id) and
         message.body == Ash.Changeset.get_argument(changeset, :body) and
         message.parts == Ash.Changeset.get_argument(changeset, :parts) do
      {:ok, message}
    else
      {:error,
       SendConflictError.exception(
         idempotency_key: Ash.Changeset.get_argument(changeset, :idempotency_key)
       )}
    end
  end
end
