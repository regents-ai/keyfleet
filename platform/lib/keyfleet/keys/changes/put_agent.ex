defmodule Keyfleet.Keys.Changes.PutAgent do
  @moduledoc """
  Puts the agent the write names by its wallet on the Key, inside the write's
  own transaction, once the policy has let the person through
  (`Keyfleet.Keys.AgentKey`): the agent must be paired with the person now,
  read from their pairings and held until the write commits
  (`RegentAgents.Authority.lock_current/3`), and its pairing's id is what is
  kept. The Key it was on in the fleet, if another, loses it. Naming no agent
  takes the Key's agent off.
  """
  use Ash.Resource.Change

  alias Keyfleet.Keys
  alias Keyfleet.Keys.AgentKey
  alias Keyfleet.Keys.Errors.AgentUnknownError

  require Ash.Query

  @impl true
  def change(changeset, _opts, %{actor: actor}),
    do: Ash.Changeset.before_action(changeset, &put(&1, actor))

  defp put(changeset, actor) do
    case Ash.Changeset.get_argument(changeset, :agent_wallet) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :paired_agent_id, nil)
      wallet -> put(changeset, actor, String.downcase(wallet))
    end
  end

  defp put(changeset, actor, wallet) do
    with {:ok, person} <- Keys.person_privy_id(actor),
         {:ok, %{id: pairing_id}} <-
           RegentAgents.Authority.lock_current(Keyfleet.Repo, person, wallet),
         :ok <- release(changeset, actor, pairing_id) do
      Ash.Changeset.force_change_attribute(changeset, :paired_agent_id, pairing_id)
    else
      not_theirs when not_theirs in [:error, {:error, :not_paired}] ->
        Ash.Changeset.add_error(changeset, AgentUnknownError.exception(wallet: wallet))

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The agent comes off the other Key it was on in this fleet.
  defp release(changeset, actor, pairing_id) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :token_id)

    AgentKey
    |> Ash.Query.filter(
      paired_agent_id == ^pairing_id and fleet_id == ^fleet_id and token_id != ^token_id
    )
    |> Ash.bulk_destroy(:release, %{},
      actor: actor,
      strategy: [:atomic, :stream],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
    end
  end
end
