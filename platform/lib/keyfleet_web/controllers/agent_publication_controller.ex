defmodule KeyfleetWeb.AgentPublicationController do
  @moduledoc """
  What the fleet's Keys made public in a project, for an agent through its
  own signed requests: list it, newest first; make a Key's own posts in one
  of the fleet's rooms public, from one post to another; make public a
  workspace item the Key added; and take back something the Key made public
  (`Keyfleet.Projects.Publication`). Anyone reads what is public on the
  workspace's Public place, signed in or not.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Fleets, Projects}
  alias Keyfleet.Graph.Errors.{CheckExpiredError, EditsRestrictedError}
  alias Keyfleet.Graph.Errors.{NotKeyHolderError, UnknownFleetError}
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Projects.Errors.{PublishError, UnknownProjectError}
  alias KeyfleetWeb.{Endpoint, Refusal, WorkspacePage}

  # How many publications a list answers, newest first.
  @listed 100

  def index(conn, %{"fleet_id" => fleet_id, "project" => name}) do
    with {:fleet, {:ok, %{}}} <- {:fleet, Fleets.get_fleet(fleet_id, actor: %System{})},
         {:project, {:ok, %{}}} <- {:project, Projects.project_page(fleet_id, name)},
         {:ok, publications} <- Projects.publications(fleet_id, name, query: [limit: @listed]) do
      json(conn, %{publications: Enum.map(publications, &publication/1)})
    else
      {:fleet, {:ok, nil}} -> Refusal.json(conn, 404, "fleet_unknown")
      {:project, {:ok, nil}} -> Refusal.json(conn, 404, "project_unknown")
      {_read, {:error, error}} -> refuse(conn, fleet_id, error)
      {:error, error} -> refuse(conn, fleet_id, error)
    end
  end

  def posts(conn, %{
        "fleet_id" => fleet_id,
        "project" => name,
        "as_key" => key,
        "room" => room,
        "from_seq" => from,
        "to_seq" => to
      }),
      do: made(conn, fleet_id, &Projects.publish_posts(fleet_id, key, name, room, from, to, &1))

  def item(conn, %{"fleet_id" => fleet_id, "as_key" => key, "item" => id}),
    do: made(conn, fleet_id, &Projects.publish_item(fleet_id, key, id, &1))

  def withdraw(conn, %{"fleet_id" => fleet_id, "publication_id" => id, "as_key" => key}),
    do: made(conn, fleet_id, &Projects.withdraw_publication(fleet_id, key, id, &1))

  defp made(conn, fleet_id, step) do
    case step.(actor: conn.assigns.agent_actor) do
      {:ok, publication} -> json(conn, %{publication: publication(publication)})
      {:error, error} -> refuse(conn, fleet_id, error)
    end
  end

  defp publication(publication) do
    %{
      id: publication.id,
      project: publication.project,
      key: publication.key,
      kind: publication.kind,
      room: publication.room,
      from_seq: publication.from_seq,
      to_seq: publication.to_seq,
      item: publication.item,
      made_at: publication.inserted_at,
      url:
        Endpoint.url() <>
          WorkspacePage.place_path(publication.fleet_id, :public, publication.project)
    }
  end

  defp refuse(conn, fleet_id, %Ash.Error.Forbidden{}) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, "not_a_key_holder"),
      else: Refusal.json(conn, 503, "ownership_refreshing")
  end

  defp refuse(conn, _fleet_id, %{errors: errors}) do
    {status, body} = Enum.find_value(errors, &answer/1) || {422, Refusal.body("publish_invalid")}
    conn |> put_status(status) |> json(body)
  end

  defp answer(%PublishError{code: code, words: words}),
    do: {status(code), put_in(Refusal.body("publish_#{code}"), [:error, :message], words)}

  defp answer(%UnknownProjectError{}), do: {404, Refusal.body("project_unknown")}
  defp answer(%UnknownFleetError{}), do: {404, Refusal.body("fleet_unknown")}
  defp answer(%OwnershipRefreshingError{}), do: {503, Refusal.body("ownership_refreshing")}
  defp answer(%NotKeyHolderError{}), do: {403, Refusal.body("not_a_key_holder")}
  defp answer(%EditsRestrictedError{}), do: {403, Refusal.body("edits_restricted")}
  defp answer(%CheckExpiredError{}), do: {503, Refusal.body("graph_unavailable")}
  defp answer(_error), do: nil

  defp status(code) when code in [:not_yours, :not_added], do: 403
  defp status(code) when code in [:unknown, :room_unknown, :key_unknown, :item_unknown], do: 404
  defp status(:range), do: 422

  defp status(code)
       when code in [:project_archived, :none_written, :item_archived, :already_public],
       do: 409
end
