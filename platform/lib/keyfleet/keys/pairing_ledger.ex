defmodule Keyfleet.Keys.PairingLedger do
  @moduledoc """
  The writes that keep one key's pairings consistent with each other.

  Each caller is an action on `Keyfleet.Keys.KeyPairing` whose own policy has
  already admitted the owner or the operator, so the consequences it draws on
  the key's other pairings run as the system.
  """

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Keys.KeyPairing

  @doc "Holds every pairing decision for one key in line until the transaction commits."
  def lock_key!(fleet_id, token_id) do
    Keyfleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["key_pairing", fleet_id, token_id])
    ])
  end

  @doc "Steps the key's attached operator down, keeping `except_id` if it is attached."
  def replace_active!(fleet_id, token_id, except_id) do
    fleet_id |> open_pairings(token_id, :active) |> except(except_id) |> end_with!(:replaced)
  end

  @doc "Closes the request this agent already left on the key, if it left one."
  def replace_open_request!(fleet_id, token_id, agent_profile_id) do
    fleet_id
    |> open_pairings(token_id, :requested)
    |> Ash.Query.filter(agent_profile_id == ^agent_profile_id)
    |> end_with!(:replaced)
  end

  @doc """
  Turns down every request left under this owner, other than `except_id`.

  Requests from before the key changed hands are left alone: the owner turning
  them down never saw them, and they are the previous owner's history.
  """
  def decline_open_requests!(fleet_id, token_id, ownership_epoch, except_id) do
    fleet_id
    |> open_pairings(token_id, :requested)
    |> Ash.Query.filter(ownership_epoch == ^ownership_epoch)
    |> except(except_id)
    |> end_with!(:declined)
  end

  defp open_pairings(fleet_id, token_id, status) do
    Ash.Query.for_read(
      KeyPairing,
      :open_pairings_on_key,
      %{fleet_id: fleet_id, token_id: token_id, status: status},
      actor: %System{}
    )
  end

  defp except(query, nil), do: query
  defp except(query, id), do: Ash.Query.filter(query, id != ^id)

  defp end_with!(query, ended_reason) do
    %Ash.BulkResult{status: :success} =
      Ash.bulk_update!(query, :end_pairing, %{ended_reason: ended_reason},
        actor: %System{},
        return_errors?: true,
        stop_on_error?: true
      )

    :ok
  end
end
