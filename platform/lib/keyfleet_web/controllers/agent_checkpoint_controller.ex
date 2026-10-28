defmodule KeyfleetWeb.AgentCheckpointController do
  @moduledoc """
  An agent's own checkpoint in one fleet, where it left off
  (`Keyfleet.Agents.Checkpoint`): read it, and save it from the revision it
  read. A save from any other revision is refused with the checkpoint as it
  is now, so the agent merges and saves again.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Agents, Fleets}
  alias KeyfleetWeb.Refusal

  def show(conn, %{"fleet_id" => fleet_id}) do
    in_fleet(conn, fleet_id, fn actor ->
      with {:ok, checkpoint} <- Agents.checkpoint(fleet_id, actor: actor),
           do: {:ok, %{checkpoint: view(checkpoint)}}
    end)
  end

  def save(conn, %{"fleet_id" => fleet_id, "expected_revision" => expected, "state" => state}) do
    in_fleet(conn, fleet_id, fn actor ->
      case Agents.save_checkpoint(actor, fleet_id, expected, state) do
        {:ok, checkpoint} -> {:ok, %{checkpoint: view(checkpoint)}}
        other -> other
      end
    end)
  end

  defp in_fleet(conn, fleet_id, act) do
    if fleet_id in Fleets.catalog_ids() do
      case act.(conn.assigns.agent_actor) do
        {:ok, answer} ->
          json(conn, answer)

        {:stale, current} ->
          conn
          |> put_status(409)
          |> json(
            put_in(Refusal.body("checkpoint_conflict"), [:error, :details], %{
              checkpoint: view(current)
            })
          )

        {:error, _error} ->
          Refusal.json(conn, 503, "checkpoint_unavailable")
      end
    else
      Refusal.json(conn, 404, "fleet_unknown")
    end
  end

  defp view(nil), do: nil

  defp view(checkpoint),
    do: Map.take(checkpoint, [:fleet_id, :revision, :state, :updated_at])
end
