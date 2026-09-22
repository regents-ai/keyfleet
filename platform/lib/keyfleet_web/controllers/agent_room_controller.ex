defmodule KeyFleetWeb.AgentRoomController do
  use KeyFleetWeb, :controller

  alias KeyFleet.Rooms
  alias KeyFleet.Rooms.Errors.ReplyOutsideRoomError
  alias KeyFleet.Rooms.Errors.RoomUnknownError
  alias KeyFleet.Rooms.Errors.SendConflictError

  @message_fields [
    :id,
    :seq,
    :author_kind,
    :author_wallet,
    :agent_profile_id,
    :body,
    :reply_to_id,
    :inserted_at
  ]

  def rooms(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor
    json(conn, %{rooms: Enum.map(Rooms.list_rooms!(fleet_id, actor: actor), &room_json/1)})
  end

  def read_messages(conn, %{"fleet_id" => fleet_id, "slug" => slug} = params) do
    actor = conn.assigns.agent_actor

    # The posts are read before the room's head, so the head answered is never
    # behind the posts answered with it.
    with {:ok, messages} <-
           Rooms.read_messages(fleet_id, slug, Map.take(params, ["after_seq", "limit"]),
             actor: actor
           ),
         %{} = room <- Rooms.get_room!(fleet_id, slug, actor: actor) do
      json(conn, %{room: room_json(room), messages: Enum.map(messages, &message_json/1)})
    else
      nil -> not_found(conn)
      {:error, error} -> refuse(conn, error)
    end
  end

  def send_message(conn, %{"fleet_id" => fleet_id, "slug" => slug} = params) do
    actor = conn.assigns.agent_actor

    input =
      params
      |> Map.take(["body", "idempotency_key", "reply_to_id"])
      |> Map.merge(%{"fleet_id" => fleet_id, "slug" => slug})

    case Rooms.send_message(input, actor: actor) do
      {:ok, message} ->
        conn |> put_status(sent_status(message)) |> json(%{message: message_json(message)})

      {:error, %Ash.Error.Forbidden{} = error} ->
        # Standing cannot be read while the fleet's key ownership is not fresh.
        if KeyFleet.Chain.fresh?(fleet_id), do: refuse(conn, error), else: refreshing(conn)

      {:error, error} ->
        refuse(conn, error)
    end
  end

  def sync(conn, %{"fleet_id" => fleet_id, "rooms" => rooms}) do
    actor = conn.assigns.agent_actor
    cursors = Enum.map(rooms, &%{slug: &1["slug"], after_seq: &1["after_seq"]})

    case Rooms.sync(fleet_id, cursors, actor) do
      {:ok, synced} -> json(conn, sync_json(synced))
      {:error, error} -> refuse(conn, error)
    end
  end

  # A repeat of a post the room already has is answered with that post, and the
  # sender is told nothing new was written.
  defp sent_status(message) do
    if Ash.Resource.get_metadata(message, :upsert_skipped), do: 200, else: 201
  end

  defp room_json(room), do: Map.take(room, [:slug, :name, :head_seq])

  defp message_json(message) do
    message
    |> Map.take(@message_fields)
    |> Map.put(:agent_profile, agent_profile_json(message.agent_profile))
  end

  defp agent_profile_json(%Ash.NotLoaded{}), do: nil
  defp agent_profile_json(nil), do: nil

  defp agent_profile_json(profile),
    do: Map.take(profile, [:id, :name, :declared_harness, :current_status])

  defp sync_json(synced) do
    %{
      rooms:
        Enum.map(synced.rooms, fn room ->
          %{
            slug: room.slug,
            head_seq: room.head_seq,
            cursor: room.cursor,
            messages: Enum.map(room.messages, &message_json/1)
          }
        end),
      proposals: synced.proposals
    }
  end

  defp refuse(conn, %Ash.Error.Forbidden{}), do: forbidden(conn)

  defp refuse(conn, %RoomUnknownError{}), do: not_found(conn)

  defp refuse(conn, %Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%RoomUnknownError{}, &1)) ->
        not_found(conn)

      Enum.any?(errors, &match?(%SendConflictError{}, &1)) ->
        invalid(conn, "idempotency_conflict")

      Enum.any?(errors, &match?(%ReplyOutsideRoomError{}, &1)) ->
        invalid(conn, "reply_not_here")

      true ->
        invalid(conn, "invalid_message")
    end
  end

  defp refuse(conn, _error), do: invalid(conn, "invalid_message")

  defp forbidden(conn), do: conn |> put_status(403) |> json(%{error: "not_a_member"})

  defp refreshing(conn),
    do: conn |> put_status(503) |> json(%{error: "ownership_refreshing"})

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "room_unknown"})

  defp invalid(conn, error), do: conn |> put_status(422) |> json(%{error: error})
end
