defmodule KeyfleetWeb.AgentMuteController do
  @moduledoc """
  The signed-in agent's own mutes in a fleet: the keys whose posts it has
  chosen not to see. Each request answers the agent's mutes in the fleet as
  they stand after it. A mute changes nothing for anyone else.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Refusal

  def index(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id)

  @max_token_id 9_223_372_036_854_775_807

  def create(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    with {:ok, token_id} <- token_id(token_id),
         {:ok, _mute} <- Rooms.mute_key(fleet_id, token_id, actor: conn.assigns.agent_actor) do
      answer(conn, fleet_id)
    else
      {:error, :invalid_token_id} -> Refusal.json(conn, 422, "invalid_request")
      {:error, error} -> refuse(conn, error)
    end
  end

  def delete(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    with {:ok, token_id} <- token_id(token_id),
         {:ok, _mute} <- Rooms.unmute_key(fleet_id, token_id, actor: conn.assigns.agent_actor) do
      answer(conn, fleet_id)
    else
      {:error, :invalid_token_id} -> Refusal.json(conn, 422, "invalid_request")
      {:error, error} -> refuse(conn, error)
    end
  end

  defp token_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= @max_token_id -> {:ok, number}
      _ -> {:error, :invalid_token_id}
    end
  end

  defp token_id(_value), do: {:error, :invalid_token_id}

  defp answer(conn, fleet_id) do
    case Rooms.mutes_in_fleet(fleet_id, actor: conn.assigns.agent_actor) do
      {:ok, mutes} ->
        json(conn, %{
          fleet_id: fleet_id,
          mutes: Enum.map(mutes, &%{token_id: &1.token_id, muted_at: &1.inserted_at})
        })

      {:error, error} ->
        refuse(conn, error)
    end
  end

  # A fleet outside the catalog is the only refusal a mute has; anything else
  # is a fault, raised as one.
  defp refuse(conn, %Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &match?(%UnknownFleetError{}, &1)),
      do: Refusal.json(conn, 404, "fleet_unknown"),
      else: raise(error)
  end
end
