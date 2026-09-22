defmodule KeyFleetWeb.AgentPairingController do
  use KeyFleetWeb, :controller

  alias KeyFleet.Keys
  alias KeyFleet.Keys.Errors.AlreadyOperatingError
  alias KeyFleet.Keys.Errors.ProfileRequiredError
  alias KeyFleet.Keys.Errors.UnknownKeyError

  @fields [
    :id,
    :fleet_id,
    :token_id,
    :ownership_epoch,
    :owner_wallet,
    :operator_wallet,
    :status,
    :ended_reason,
    :effective?,
    :requested_at,
    :approved_at,
    :ended_at
  ]

  def index(conn, _params) do
    actor = conn.assigns.agent_actor
    json(conn, %{pairings: Enum.map(Keys.my_pairings!(actor: actor), &pairing_json/1)})
  end

  def create(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    actor = conn.assigns.agent_actor

    case Keys.request_pairing(fleet_id, String.to_integer(token_id), %{}, actor: actor) do
      {:ok, pairing} -> json(conn, %{pairing: pairing_json(pairing, actor)})
      {:error, error} -> refuse(conn, error)
    end
  end

  def delete(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    actor = conn.assigns.agent_actor
    token_id = String.to_integer(token_id)

    with {:ok, request} when not is_nil(request) <-
           Keys.my_open_request(fleet_id, token_id, actor: actor),
         {:ok, withdrawn} <- Keys.withdraw_pairing_request(request, %{}, actor: actor) do
      json(conn, %{pairing: pairing_json(withdrawn, actor)})
    else
      {:ok, nil} -> conn |> put_status(404) |> json(%{error: "pairing_not_found"})
      {:error, error} -> refuse(conn, error)
    end
  end

  defp pairing_json(pairing), do: Map.take(pairing, @fields)

  # A pairing the agent has just opened or taken back is answered with the
  # standing the list endpoint would give it, which the key itself decides.
  defp pairing_json(pairing, actor),
    do: pairing |> Ash.load!(:effective?, action: :my_pairings, actor: actor) |> pairing_json()

  defp refuse(conn, %Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%UnknownKeyError{}, &1)) ->
        not_found(conn, "key_not_found")

      Enum.any?(errors, &match?(%ProfileRequiredError{}, &1)) ->
        not_found(conn, "profile_not_found")

      Enum.any?(errors, &match?(%AlreadyOperatingError{}, &1)) ->
        conflict(conn, "already_operating")

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        conflict(conn, "pairing_already_decided")

      true ->
        invalid(conn)
    end
  end

  defp refuse(conn, _error), do: invalid(conn)

  defp not_found(conn, error), do: conn |> put_status(404) |> json(%{error: error})

  defp conflict(conn, error), do: conn |> put_status(409) |> json(%{error: error})

  defp invalid(conn), do: conn |> put_status(422) |> json(%{error: "invalid_pairing"})
end
