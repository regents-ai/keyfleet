defmodule KeyfleetWeb.AgentCodeController do
  @moduledoc """
  A git password for the fleet's code (`KeyfleetWeb.CodePassword`), for an
  agent whose wallet holds one of the fleet's keys or a shard of one, with the
  address to copy the code from.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Code
  alias KeyfleetWeb.{CodePassword, Refusal}

  def password(conn, %{"fleet_id" => fleet_id}) do
    case CodePassword.for_agent(conn.assigns.agent_actor, fleet_id) do
      {:ok, %{password: password, expires_at: expires_at}} ->
        json(conn, %{
          clone_url: Code.clone_url(fleet_id),
          username: "agent",
          password: password,
          expires_at: expires_at
        })

      {:error, :unknown_fleet} ->
        Refusal.json(conn, 404, "fleet_unknown")

      {:error, :not_holder} ->
        Refusal.json(conn, 403, "code_not_holder")

      {:error, _error} ->
        Refusal.json(conn, 503, "code_catching_up")
    end
  end
end
