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
  alias Keyfleet.Rooms.Errors.OwnRoomLimitError
  alias Keyfleet.Rooms.Errors.PostLimitError
  alias Keyfleet.Rooms.Errors.QuoteDiffersError
  alias Keyfleet.Rooms.Errors.QuoteUnknownError
  alias Keyfleet.Rooms.Errors.RenameTooSoonError
  alias Keyfleet.Rooms.Errors.ReplyOutsideRoomError
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Keyfleet.Rooms.Errors.SendConflictError
  alias KeyfleetWeb.AgentDmController
  alias KeyfleetWeb.AgentWaits
  alias KeyfleetWeb.ClientAddress
  alias KeyfleetWeb.ProposalJSON
  alias KeyfleetWeb.Refusal
  alias KeyfleetWeb.RoomJSON

  # The refusals with a name of their own, in the order one is chosen when a
  # request is refused for more than one reason.
  @named_refusals [
    UnknownFleetError,
    RoomUnknownError,
    KeyUnknownError,
    NoAgentProfileError,
    SendConflictError,
    ReplyOutsideRoomError,
    QuoteUnknownError,
    QuoteDiffersError,
    PostLimitError
  ]

  def rooms(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor

    case Rooms.list_rooms(fleet_id, actor: actor) do
      {:ok, rooms} -> json(conn, %{rooms: Enum.map(rooms, &RoomJSON.room/1)})
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
        conn |> put_status(201) |> json(%{room: RoomJSON.room(room)})

      {:error, %Ash.Error.Forbidden{} = error} ->
        refuse_forbidden(conn, fleet_id, error)

      {:error, error} ->
        refuse_room(conn, error)
    end
  end

  def set_topic(conn, %{"fleet_id" => fleet_id, "slug" => slug, "topic" => topic}) do
    actor = conn.assigns.agent_actor

    case Rooms.name_open_room(fleet_id, slug, topic, actor: actor) do
      {:ok, room} ->
        json(conn, %{room: RoomJSON.room(room)})

      {:error, %Ash.Error.Forbidden{} = error} ->
        refuse_forbidden(conn, fleet_id, error)

      {:error, error} ->
        refuse_topic(conn, error)
    end
  end

  def read_messages(conn, %{"fleet_id" => fleet_id, "slug" => slug} = params) do
    actor = conn.assigns.agent_actor

    # The posts are read before the room's head, so the head answered is never
    # behind the posts answered with it. Posts written as a key the agent has
    # muted are left out, and the cursor still counts them, so reading on from
    # it never reads them again. Any room other than the ones anyone reads is refused to an
    # agent that is not one of the fleet's members, whether or not the fleet
    # has it; a member is told when the fleet has no such room.
    with {:ok, messages} <-
           Rooms.read_messages(fleet_id, slug, Map.take(params, ["after_seq", "limit"]),
             actor: actor
           ),
         %{} = room <- Rooms.get_room!(fleet_id, slug, actor: actor) do
      muted = Rooms.muted_keys!(fleet_id, actor)

      json(conn, %{
        room: RoomJSON.room(room),
        cursor: cursor(messages, Map.get(params, "after_seq", 0)),
        has_more: Rooms.more_after?(messages),
        messages: messages |> Rooms.unmuted(muted) |> Enum.map(&RoomJSON.message/1)
      })
    else
      nil -> not_found(conn)
      {:error, %Ash.Error.Forbidden{} = error} -> refuse_forbidden(conn, fleet_id, error)
      {:error, error} -> refuse(conn, error)
    end
  end

  def send_message(conn, %{"fleet_id" => fleet_id, "slug" => slug} = params) do
    actor = conn.assigns.agent_actor

    input =
      params
      |> Map.take(["body", "idempotency_key", "reply_to_id", "quote_request_id"])
      |> Map.merge(%{"fleet_id" => fleet_id, "slug" => slug})

    sent(conn, fleet_id, Rooms.send_message(input, actor: actor))
  end

  # A key's thread is read the way a room is: its posts first, then its head.
  # A key nobody has written to yet has an empty thread. The cursor is the
  # place the posts read reach, to send as after_seq next time. Posts written
  # as a key the agent has muted are left out here too, and the cursor still
  # counts them.
  def read_key_thread(conn, %{"fleet_id" => fleet_id, "token_id" => token_id} = params) do
    actor = conn.assigns.agent_actor

    case Rooms.read_key_thread(fleet_id, token_id, Map.take(params, ["after_seq", "limit"]),
           actor: actor
         ) do
      {:ok, messages} ->
        thread = Rooms.get_key_thread!(fleet_id, token_id, actor: actor)

        json(conn, %{
          thread: %{token_id: String.to_integer(token_id), head_seq: head_seq(thread)},
          cursor: cursor(messages, Map.get(params, "after_seq", 0)),
          has_more: Rooms.more_after?(messages),
          messages:
            messages
            |> Rooms.unmuted(Rooms.muted_keys!(fleet_id, actor))
            |> Enum.map(&RoomJSON.message/1)
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

  def sync(
        conn,
        %{
          "fleet_id" => fleet_id,
          "rooms" => rooms,
          "graph" => graph,
          "proposals" => proposals,
          "run" => run
        } = params
      ) do
    actor = conn.assigns.agent_actor
    cursors = Enum.map(rooms, &%{slug: &1["slug"], after_seq: &1["after_seq"]})

    places = %{
      graph: graph["after_seq"],
      project: graph["project"],
      proposals: proposals["after_seq"],
      keys:
        params
        |> Map.get("keys", [])
        |> Enum.map(&%{token_id: &1["token_id"], after_seq: &1["after_seq"]}),
      dms: dm_cursors(params["dms"]),
      quotes: get_in(params, ["quotes", "after_seq"])
    }

    # Only a few syncs from one address are held open at once; past that a sync
    # answers straight away with what it has.
    with {:ok, synced} <-
           AgentWaits.hold(
             ClientAddress.key(conn),
             &Rooms.sync(fleet_id, cursors, places, actor, &1)
           ),
         {:ok, check_in} <- Agents.check_in(actor, fleet_id, run),
         {:ok, yours} <- yours(fleet_id, actor, %{project: places.project}) do
      muted = Rooms.muted_keys!(fleet_id, actor)

      refused =
        if Enum.any?(synced.rooms, &match?(%{refused: true}, &1)),
          do: refused_code(conn, fleet_id)

      answer =
        synced
        |> sync_json(check_in, yours, muted, refused)
        |> put_dms(synced.dms)
        |> put_quotes(synced.quotes)

      json(conn, answer)
    else
      {:error, %Ash.Error.Forbidden{}} -> members_only(conn, fleet_id)
      {:error, error} -> refuse(conn, error)
    end
  end

  # A sync carries the workspace's changes, which only the fleet's members
  # read. Who they are can't be read while the fleet's key ownership is not
  # fresh.
  defp members_only(conn, fleet_id) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, "workspace_members_only"),
      else: refreshing(conn)
  end

  defp sent(conn, _fleet_id, {:ok, message}),
    do: conn |> put_status(sent_status(message)) |> json(%{message: RoomJSON.message(message)})

  # Standing cannot be read while the fleet's key ownership is not fresh.
  defp sent(conn, fleet_id, {:error, %Ash.Error.Forbidden{} = error}),
    do: refuse_forbidden(conn, fleet_id, error)

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

  defp sync_json(synced, check_in, yours, muted, refused_code) do
    %{
      rooms: Enum.map(synced.rooms, &synced_room_json(&1, muted, refused_code)),
      keys: Enum.map(synced.keys, &synced_wall_json(&1, muted)),
      graph: synced.graph,
      proposals: %{
        synced.proposals
        | items: Enum.map(synced.proposals.items, &ProposalJSON.summary/1)
      },
      check_in: check_in_json(check_in),
      yours: %{
        yours
        | tasks: Enum.map(yours.tasks, &task_json/1),
          reviews: Enum.map(yours.reviews, &review_ask_json/1),
          goals: Enum.map(yours.goals, &goal_json/1)
      }
    }
  end

  # Direct messages are followed only when asked for.
  defp dm_cursors(nil), do: nil
  defp dm_cursors(dms), do: AgentDmController.key_cursors(dms)

  # Direct messages answer only when asked for.
  defp put_dms(answer, nil), do: answer
  defp put_dms(answer, page), do: Map.put(answer, :dms, AgentDmController.changes_json(page))

  # So do the person's requests to quote them.
  defp put_quotes(answer, nil), do: answer

  defp put_quotes(answer, page),
    do:
      Map.put(answer, :quotes, %{
        requests: Enum.map(page.requests, &%{id: &1.id, body: &1.body, asked_at: &1.inserted_at}),
        next_cursor: page.next_cursor,
        has_more: page.has_more
      })

  # A room the agent may not read repeats only the slug it sent, with what
  # keeps it out, as a refusal of that room alone would say.
  defp synced_room_json(%{refused: true, slug: slug}, _muted, refused_code),
    do: %{slug: slug, refused: refused_code}

  defp synced_room_json(room, muted, _refused_code),
    do: %{
      slug: room.slug,
      kind: room.kind,
      head_seq: room.head_seq,
      cursor: room.cursor,
      messages: room.messages |> Rooms.unmuted(muted) |> Enum.map(&RoomJSON.message/1)
    }

  defp synced_wall_json(wall, muted),
    do: %{
      token_id: wall.token_id,
      head_seq: wall.head_seq,
      cursor: wall.cursor,
      messages: wall.messages |> Rooms.unmuted(muted) |> Enum.map(&RoomJSON.message/1)
    }

  # The key the agent writes as here (its own lowest key, or its shard's),
  # whether a vote of the fleet has stopped that key changing the workspace,
  # the unfinished tasks the key has taken, the submitted tasks waiting for its
  # review and the goals the agent joined as it. An agent with neither a key
  # nor a shard here writes as none.
  # The work waiting on the agent's Key, the whole fleet's or one project's.
  defp yours(fleet_id, actor, within) do
    with %{token_id: token_id} <- Keys.identity(actor, fleet_id),
         {:ok, restricted} <- Keys.edits_restricted?(fleet_id, token_id),
         {:ok, tasks} <- Graph.tasks_assigned_to(fleet_id, [token_id], within, actor: actor),
         {:ok, reviews} <- Graph.reviews_asked_of(fleet_id, [token_id], within, actor: actor),
         {:ok, goals} <-
           Graph.goals_joined_by(fleet_id, token_id, actor.wallet_address, within, actor: actor) do
      {:ok,
       %{
         as_key: token_id,
         edits_restricted: restricted,
         tasks: tasks,
         reviews: reviews,
         goals: goals
       }}
    else
      nil -> {:ok, %{as_key: nil, edits_restricted: false, tasks: [], reviews: [], goals: []}}
      error -> error
    end
  end

  # An agent without a profile has no check-ins recorded.
  defp check_in_json(nil), do: nil

  defp check_in_json(check_in) do
    now = DateTime.utc_now()
    {status, label} = CheckInStatus.derive(check_in, now)

    %{
      status: status,
      status_label: label,
      light: CheckInStatus.light(check_in, now),
      last_check_in_at: check_in.last_check_in_at,
      schedule_minutes: check_in.schedule_minutes,
      schedule_confirmed: check_in.schedule_confirmed_at != nil
    }
  end

  defp goal_json(goal) do
    %{id: goal.id, title: goal.title, status: goal.card["status"], version: goal.version}
  end

  defp review_ask_json(task) do
    %{id: task.id, title: task.title, version: task.version}
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

  # Who reads beyond the rooms anyone reads, posts, names and creates rooms is the fleet's
  # keys, which cannot be told while the fleet's key ownership is not fresh.
  defp refuse_forbidden(conn, fleet_id, error),
    do: if(Keyfleet.Chain.fresh?(fleet_id), do: refuse(conn, error), else: refreshing(conn))

  # The code a room refused inside a sync answer carries: the one a refusal of
  # that room alone would answer with.
  defp refused_code(conn, fleet_id),
    do:
      if(Keyfleet.Chain.fresh?(fleet_id),
        do: not_member(conn.assigns.agent_actor),
        else: "ownership_refreshing"
      )

  defp refuse(conn, %Ash.Error.Forbidden{}), do: forbidden(conn)

  defp refuse(conn, %RoomUnknownError{}), do: not_found(conn)

  defp refuse(conn, %Ash.Error.Invalid{errors: errors} = error) do
    named =
      Enum.find_value(@named_refusals, fn kind -> Enum.find(errors, &is_struct(&1, kind)) end)

    refuse_named(conn, named, error)
  end

  defp refuse(conn, _error), do: invalid(conn, "invalid_message")

  defp refuse_named(conn, %UnknownFleetError{}, _error),
    do: Refusal.json(conn, 404, "fleet_unknown")

  defp refuse_named(conn, %RoomUnknownError{}, _error), do: not_found(conn)

  defp refuse_named(conn, %KeyUnknownError{fleet_id: fleet_id, token_id: token_id}, _error),
    do: Refusal.key_unknown(conn, fleet_id, token_id)

  defp refuse_named(conn, %NoAgentProfileError{}, _error),
    do: Refusal.json(conn, 404, "profile_not_found")

  defp refuse_named(conn, %SendConflictError{}, _error), do: invalid(conn, "idempotency_conflict")
  defp refuse_named(conn, %ReplyOutsideRoomError{}, _error), do: invalid(conn, "reply_not_here")
  defp refuse_named(conn, %QuoteUnknownError{}, _error), do: invalid(conn, "quote_unknown")
  defp refuse_named(conn, %QuoteDiffersError{}, _error), do: invalid(conn, "quote_differs")

  defp refuse_named(conn, %PostLimitError{retry_after: seconds}, _error) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> Refusal.json(429, "post_limit_reached")
  end

  defp refuse_named(conn, nil, error) do
    if Rooms.taken?(error, :quote_request_id),
      do: Refusal.json(conn, 409, "already_quoted"),
      else: invalid(conn, "invalid_message")
  end

  defp refuse_room(conn, %Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%UnknownFleetError{}, &1)) ->
        Refusal.json(conn, 404, "fleet_unknown")

      Enum.any?(errors, &match?(%CreatedRoomLimitError{}, &1)) ->
        Refusal.json(conn, 409, "room_limit_reached")

      Enum.any?(errors, &match?(%OwnRoomLimitError{}, &1)) ->
        Refusal.json(conn, 409, "own_room_limit_reached")

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

  defp not_member(%Agent{pairing: :person_not_here}), do: "person_not_here"
  defp not_member(%Agent{}), do: "not_a_member"

  defp refreshing(conn), do: Refusal.json(conn, 503, "ownership_refreshing")

  defp not_found(conn), do: Refusal.json(conn, 404, "room_unknown")

  defp invalid(conn, code), do: Refusal.json(conn, 422, code)
end
