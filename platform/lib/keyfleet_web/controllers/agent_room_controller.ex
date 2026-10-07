defmodule KeyfleetWeb.AgentRoomController do
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.CreatedRoomLimitError
  alias Keyfleet.Rooms.Errors.KeyUnknownError
  alias Keyfleet.Rooms.Errors.NoAgentProfileError
  alias Keyfleet.Rooms.Errors.RenameTooSoonError
  alias Keyfleet.Rooms.Errors.ReplyOutsideRoomError
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Keyfleet.Rooms.Errors.SendConflictError
  alias KeyfleetWeb.ProposalJSON
  alias KeyfleetWeb.Refusal

  @room_fields [:slug, :name, :kind, :topic, :topic_set_by, :topic_set_at, :head_seq]

  @message_fields [
    :id,
    :seq,
    :kind,
    :author_kind,
    :author_wallet,
    :as_key,
    :agent_profile_id,
    :body,
    :reply_to_id,
    :inserted_at
  ]

  def rooms(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor

    case Rooms.list_rooms(fleet_id, actor: actor) do
      {:ok, rooms} -> json(conn, %{rooms: Enum.map(rooms, &room_json/1)})
      {:error, error} -> refuse(conn, error)
    end
  end

  def create_room(conn, %{"fleet_id" => fleet_id} = params) do
    actor = conn.assigns.agent_actor

    input =
      params
      |> Map.take(["slug", "name"])
      |> Map.put("fleet_id", fleet_id)

    case Rooms.create_room(input, actor: actor) do
      {:ok, room} ->
        conn |> put_status(201) |> json(%{room: room_json(room)})

      {:error, %Ash.Error.Forbidden{} = error} ->
        if Keyfleet.Chain.fresh?(fleet_id), do: refuse(conn, error), else: refreshing(conn)

      {:error, error} ->
        refuse_room(conn, error)
    end
  end

  def set_topic(conn, %{"fleet_id" => fleet_id, "slug" => slug, "topic" => topic}) do
    actor = conn.assigns.agent_actor

    case Rooms.name_open_room(fleet_id, slug, topic, actor: actor) do
      {:ok, room} ->
        json(conn, %{room: room_json(room)})

      {:error, %Ash.Error.Forbidden{} = error} ->
        if Keyfleet.Chain.fresh?(fleet_id), do: refuse(conn, error), else: refreshing(conn)

      {:error, error} ->
        refuse_topic(conn, error)
    end
  end

  def read_messages(conn, %{"fleet_id" => fleet_id, "slug" => slug} = params) do
    actor = conn.assigns.agent_actor

    # The posts are read before the room's head, so the head answered is never
    # behind the posts answered with it. Posts written as a key the agent has
    # muted are left out, and the cursor still counts them, so reading on from
    # it never reads them again.
    with {:ok, messages} <-
           Rooms.read_messages(fleet_id, slug, Map.take(params, ["after_seq", "limit"]),
             actor: actor
           ),
         %{} = room <- Rooms.get_room!(fleet_id, slug, actor: actor) do
      muted = Rooms.muted_keys!(fleet_id, actor)

      json(conn, %{
        room: room_json(room),
        cursor: cursor(messages, Map.get(params, "after_seq", 0)),
        messages: messages |> Rooms.unmuted(muted) |> Enum.map(&message_json/1)
      })
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

    sent(conn, fleet_id, Rooms.send_message(input, actor: actor))
  end

  # A key's thread is read the way a room is: its posts first, then its head.
  # A key nobody has written to yet has an empty thread.
  def read_key_thread(conn, %{"fleet_id" => fleet_id, "token_id" => token_id} = params) do
    actor = conn.assigns.agent_actor

    case Rooms.read_key_thread(fleet_id, token_id, Map.take(params, ["after_seq", "limit"]),
           actor: actor
         ) do
      {:ok, messages} ->
        thread = Rooms.get_key_thread!(fleet_id, token_id, actor: actor)

        json(conn, %{
          thread: %{token_id: String.to_integer(token_id), head_seq: head_seq(thread)},
          messages: Enum.map(messages, &message_json/1)
        })

      {:error, error} ->
        refuse(conn, error)
    end
  end

  def send_to_key(conn, %{"fleet_id" => fleet_id, "token_id" => token_id} = params) do
    actor = conn.assigns.agent_actor

    input =
      params
      |> Map.take(["body", "idempotency_key", "reply_to_id"])
      |> Map.merge(%{"fleet_id" => fleet_id, "token_id" => token_id})

    sent(conn, fleet_id, Rooms.send_to_key(input, actor: actor))
  end

  def sync(conn, %{
        "fleet_id" => fleet_id,
        "rooms" => rooms,
        "graph" => graph,
        "proposals" => proposals,
        "run" => run
      }) do
    actor = conn.assigns.agent_actor
    cursors = Enum.map(rooms, &%{slug: &1["slug"], after_seq: &1["after_seq"]})

    with {:ok, synced} <-
           Rooms.sync(fleet_id, cursors, graph["after_seq"], proposals["after_seq"], actor),
         {:ok, check_in} <- Agents.check_in(actor, fleet_id, run),
         {:ok, yours} <- yours(fleet_id, actor) do
      json(conn, sync_json(synced, check_in, yours, Rooms.muted_keys!(fleet_id, actor)))
    else
      {:error, error} -> refuse(conn, error)
    end
  end

  defp sent(conn, _fleet_id, {:ok, message}),
    do: conn |> put_status(sent_status(message)) |> json(%{message: message_json(message)})

  # Standing cannot be read while the fleet's key ownership is not fresh.
  defp sent(conn, fleet_id, {:error, %Ash.Error.Forbidden{} = error}),
    do: if(Keyfleet.Chain.fresh?(fleet_id), do: refuse(conn, error), else: refreshing(conn))

  defp sent(conn, _fleet_id, {:error, error}), do: refuse(conn, error)

  defp cursor([], after_seq), do: after_seq
  defp cursor(messages, _after_seq), do: List.last(messages).seq

  defp head_seq(nil), do: 0
  defp head_seq(thread), do: thread.head_seq

  # A repeat of a post the room already has is answered with that post, and the
  # sender is told nothing new was written.
  defp sent_status(message) do
    if Ash.Resource.get_metadata(message, :upsert_skipped), do: 200, else: 201
  end

  defp room_json(room), do: Map.take(room, @room_fields)

  defp message_json(message) do
    message
    |> Map.take(@message_fields)
    |> Map.put(:author_human_backed, match?(%{human_backed: true}, message.agent_profile))
    |> Map.put(:agent_profile, agent_profile_json(message.agent_profile))
    |> Map.put(:via_agent, agent_profile_json(message.via_agent_profile))
  end

  defp agent_profile_json(%Ash.NotLoaded{}), do: nil
  defp agent_profile_json(nil), do: nil

  defp agent_profile_json(profile),
    do: Map.take(profile, [:id, :name, :declared_harness, :current_status])

  defp sync_json(synced, check_in, yours, muted) do
    %{
      rooms:
        Enum.map(synced.rooms, fn room ->
          %{
            slug: room.slug,
            kind: room.kind,
            head_seq: room.head_seq,
            cursor: room.cursor,
            messages: room.messages |> Rooms.unmuted(muted) |> Enum.map(&message_json/1)
          }
        end),
      graph: synced.graph,
      proposals: %{
        synced.proposals
        | items: Enum.map(synced.proposals.items, &ProposalJSON.summary/1)
      },
      next_poll_seconds: synced.next_poll_seconds,
      check_in: check_in_json(check_in),
      yours: %{yours | tasks: Enum.map(yours.tasks, &task_json/1)}
    }
  end

  # The key the agent writes as here (its own lowest key, or its shard's),
  # whether a vote of the fleet has stopped that key changing the workspace,
  # and the unfinished tasks the key has taken. An agent with neither a key
  # nor a shard here writes as none.
  defp yours(fleet_id, actor) do
    with %{token_id: token_id} <- Keys.identity(actor, fleet_id),
         {:ok, restricted} <- Keys.edits_restricted?(fleet_id, token_id),
         {:ok, tasks} <- Graph.tasks_assigned_to(fleet_id, [token_id]) do
      {:ok, %{as_key: token_id, edits_restricted: restricted, tasks: tasks}}
    else
      nil -> {:ok, %{as_key: nil, edits_restricted: false, tasks: []}}
      error -> error
    end
  end

  # An agent without a profile has no check-ins recorded.
  defp check_in_json(nil), do: nil

  defp check_in_json(check_in) do
    {status, label} = CheckInStatus.derive(check_in, DateTime.utc_now())

    %{
      status: status,
      status_label: label,
      last_check_in_at: check_in.last_check_in_at,
      schedule_minutes: check_in.schedule_minutes,
      schedule_confirmed: check_in.schedule_confirmed_at != nil
    }
  end

  defp task_json(task) do
    %{
      id: task.id,
      title: task.title,
      progress: task.card["progress"],
      next_step: task.next_step,
      version: task.version
    }
  end

  defp refuse(conn, %Ash.Error.Forbidden{}), do: forbidden(conn)

  defp refuse(conn, %RoomUnknownError{}), do: not_found(conn)

  defp refuse(conn, %Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%UnknownFleetError{}, &1)) ->
        Refusal.json(conn, 404, "fleet_unknown")

      Enum.any?(errors, &match?(%RoomUnknownError{}, &1)) ->
        not_found(conn)

      Enum.any?(errors, &match?(%KeyUnknownError{}, &1)) ->
        Refusal.json(conn, 404, "key_unknown")

      Enum.any?(errors, &match?(%NoAgentProfileError{}, &1)) ->
        Refusal.json(conn, 404, "profile_not_found")

      Enum.any?(errors, &match?(%SendConflictError{}, &1)) ->
        invalid(conn, "idempotency_conflict")

      Enum.any?(errors, &match?(%ReplyOutsideRoomError{}, &1)) ->
        invalid(conn, "reply_not_here")

      true ->
        invalid(conn, "invalid_message")
    end
  end

  defp refuse(conn, _error), do: invalid(conn, "invalid_message")

  defp refuse_room(conn, %Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%UnknownFleetError{}, &1)) ->
        Refusal.json(conn, 404, "fleet_unknown")

      Enum.any?(errors, &match?(%CreatedRoomLimitError{}, &1)) ->
        Refusal.json(conn, 409, "room_limit_reached")

      Rooms.taken?(error, :slug) ->
        Refusal.json(conn, 409, "room_taken")

      Rooms.taken?(error, :name) ->
        name_taken(conn)

      true ->
        invalid(conn, "invalid_room")
    end
  end

  defp refuse_room(conn, _error), do: invalid(conn, "invalid_room")

  defp refuse_topic(conn, %RoomUnknownError{}), do: not_found(conn)

  defp refuse_topic(conn, %Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%UnknownFleetError{}, &1)) ->
        Refusal.json(conn, 404, "fleet_unknown")

      Enum.any?(errors, &match?(%{field: :kind}, &1)) ->
        invalid(conn, "room_not_open")

      Rooms.taken?(error, :name) ->
        name_taken(conn)

      too_soon = Enum.find(errors, &match?(%RenameTooSoonError{}, &1)) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(too_soon.retry_after))
        |> Refusal.json(429, "rename_too_soon")

      true ->
        invalid(conn, "invalid_topic")
    end
  end

  defp refuse_topic(conn, _error), do: invalid(conn, "invalid_topic")

  # Another room of the fleet already goes by this name.
  defp name_taken(conn), do: Refusal.json(conn, 409, "name_taken")

  # An agent with no standing of its own that is paired with a person is told
  # what keeps it from writing as them.
  defp forbidden(conn), do: Refusal.json(conn, 403, not_member(conn.assigns.agent_actor))

  defp not_member(%Agent{pairing: :not_backed}), do: "agent_not_backed"
  defp not_member(%Agent{pairing: :person_not_here}), do: "person_not_here"
  defp not_member(%Agent{}), do: "not_a_member"

  defp refreshing(conn), do: Refusal.json(conn, 503, "ownership_refreshing")

  defp not_found(conn), do: Refusal.json(conn, 404, "room_unknown")

  defp invalid(conn, code), do: Refusal.json(conn, 422, code)
end
