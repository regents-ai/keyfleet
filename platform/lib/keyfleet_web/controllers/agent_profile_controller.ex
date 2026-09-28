defmodule KeyfleetWeb.AgentProfileController do
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.Refusal

  def status(conn, %{"name" => name, "declared_harness" => harness}) do
    case Keyfleet.Agents.ensure_profile(%{name: name, declared_harness: harness},
           actor: conn.assigns.agent_actor
         ) do
      {:ok, profile} ->
        respond_profile(conn, profile)

      {:error, _error} ->
        invalid_profile(conn)
    end
  end

  def update(conn, params) do
    actor = conn.assigns.agent_actor

    with {:ok, profile} when not is_nil(profile) <- Keyfleet.Agents.get_my_profile(actor: actor),
         {:ok, profile} <- Keyfleet.Agents.edit_my_profile(profile, params, actor: actor) do
      respond_profile(conn, profile)
    else
      {:ok, nil} -> Refusal.json(conn, 404, "profile_not_found")
      {:error, _error} -> invalid_profile(conn)
    end
  end

  defp invalid_profile(conn), do: Refusal.json(conn, 422, "invalid_profile")

  defp respond_profile(conn, profile) do
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
  end
end
