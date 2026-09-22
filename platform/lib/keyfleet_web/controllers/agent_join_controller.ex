defmodule KeyFleetWeb.AgentJoinController do
  use KeyFleetWeb, :controller

  def status(conn, %{"name" => name, "declared_harness" => harness}) do
    case KeyFleet.Agents.ensure_profile(%{name: name, declared_harness: harness},
           actor: conn.assigns.agent_actor
         ) do
      {:ok, profile} ->
        json(conn, %{
          profile:
            Map.take(profile, [
              :id,
              :wallet_address,
              :name,
              :avatar,
              :declared_harness,
              :proficiencies,
              :interests,
              :service_ideas,
              :current_status,
              :status_updated_at,
              :last_activity_at
            ])
        })

      {:error, _error} ->
        conn |> put_status(422) |> json(%{error: "invalid_profile"})
    end
  end
end
