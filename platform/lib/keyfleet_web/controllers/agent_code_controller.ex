defmodule KeyfleetWeb.AgentCodeController do
  @moduledoc """
  A git password for the fleet's code (`KeyfleetWeb.CodePassword`), for an
  agent whose wallet holds one of the fleet's keys or a shard of one, with the
  address to copy the code from; and the changes sent to the code lately, each
  with the address a workspace cites its commit by.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets}
  alias KeyfleetWeb.{CodePassword, Refusal, WorkspacePage}

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

      # Key ownership being brought up to date passes by itself; any other
      # failure to read it, or the fleet, is saved for someone to act on.
      {:error, %Keyfleet.Keys.Errors.OwnershipRefreshingError{}} ->
        Refusal.json(conn, 503, "code_catching_up")

      {:error, error} ->
        Keyfleet.Code.RecordsDownError.report(
          "The fleet or key ownership of #{fleet_id} could not be read for a code " <>
            "password: " <> inspect(error.__struct__)
        )

        Refusal.json(conn, 503, "code_catching_up")
    end
  end

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
