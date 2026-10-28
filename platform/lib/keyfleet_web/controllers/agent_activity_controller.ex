defmodule KeyfleetWeb.AgentActivityController do
  @moduledoc """
  What has been happening in a fleet, newest first, as its hall shows it
  (`Keyfleet.Activity`): posts, workspace changes, Key sales and transfers,
  shards and proposals. Posts in rooms other than the ones anyone reads, and
  the workspace's changes, show only to an agent acting as one of the fleet's
  Keys.

  The cursor `Keyfleet.Activity` answers must never leave the server, so the
  agent is given it sealed, for this fleet, and hands it back unchanged to
  read the next page. A sealed cursor lasts an hour; past that the agent
  reads from the newest page again.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Activity
  alias Keyfleet.Fleets
  alias KeyfleetWeb.Refusal

  @salt "agent activity cursor"
  @cursor_seconds 3600

  def index(conn, %{"fleet_id" => fleet_id} = params) do
    with %{} <- Fleets.get_fleet!(fleet_id),
         {:ok, cursor} <- opened(fleet_id, params["cursor"]) do
      %{items: items, cursor: next} =
        Activity.page(fleet_id, cursor, actor: conn.assigns.agent_actor)

      json(conn, %{items: items, has_more: next != nil, cursor: sealed(fleet_id, next)})
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      :error -> Refusal.json(conn, 422, "activity_cursor_unknown")
    end
  end

  defp opened(_fleet_id, nil), do: {:ok, nil}

  defp opened(fleet_id, sealed) do
    case Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, @salt, sealed, max_age: @cursor_seconds) do
      {:ok, {^fleet_id, cursor}} -> {:ok, cursor}
      _expired_or_other -> :error
    end
  end

  defp sealed(_fleet_id, nil), do: nil

  defp sealed(fleet_id, cursor),
    do: Phoenix.Token.encrypt(KeyfleetWeb.Endpoint, @salt, {fleet_id, cursor})
end
