defmodule KeyfleetWeb.AgentCodeController do
  @moduledoc """
  The changes sent to the fleet's code lately, each with the address a
  workspace cites its commit by. Git itself reaches the code through
  `KeyfleetWeb.Plugs.CodeGateway`.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets}
  alias KeyfleetWeb.{Refusal, WorkspacePage}

  def pushes(conn, %{"fleet_id" => fleet_id}) do
    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, pushes} <- Code.recent_pushes(fleet_id, actor: conn.assigns.agent_actor) do
      json(conn, %{
        pushes:
          for push <- pushes do
            %{
              ref: push.ref,
              commit: push.head,
              commit_url: WorkspacePage.commit_url(fleet_id, push.head),
              token_id: push.token_id,
              pushed_at: push.pushed_at
            }
          end
      })
    else
      {:ok, nil} ->
        Refusal.json(conn, 404, "fleet_unknown")

      {:error, %Ash.Error.Forbidden{}} ->
        if Keyfleet.Chain.fresh?(fleet_id),
          do: Refusal.json(conn, 403, "code_not_holder"),
          else: Refusal.json(conn, 503, "ownership_refreshing")

      {:error, error} ->
        Keyfleet.Code.RecordsDownError.report(
          "The changes sent to the code of #{fleet_id} could not be read: " <>
            inspect(error.__struct__)
        )

        Refusal.json(conn, 503, "code_catching_up")
    end
  end
end
