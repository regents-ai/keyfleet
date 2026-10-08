defmodule KeyfleetWeb.RoomTools do
  @moduledoc """
  What the browser tools on a fleet's rooms page and in a Key's window do for
  a browser's own agent: read the fleet's rooms and the messages written to
  the Key, post as the person signed in on the page, and mute or unmute a Key
  for them. Each goes through the same actions as the page's own boxes and
  buttons, as that person, and is turned down for the same reasons. The page
  shows what changed the way it shows anyone else's post or mute.

  Every answer is `%{ok: true, ...}` with the fields the agent API answers, or
  `%{ok: false, error: %{code, message, hint}}`. `priv/tool_manifest.json`
  describes each tool; `assets/js/page_tools.ts` offers them.
  """

  alias Keyfleet.Chain
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.PostLimitError
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Keyfleet.Rooms.Muter
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.RoomJSON
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.ShellLive

  @room_tools ~w(list_rooms read_room post_to_room mute_key unmute_key)
  @key_tools ~w(read_key_thread post_to_key_thread)
  @max_token_id 9_223_372_036_854_775_807

  @doc "Answers one call of the named tool, against what the page shows now."
  def call(tool, input, socket) do
    {:reply, answer(tool, input, socket.assigns, ShellLive.human_actor(socket)), socket}
  end

  # Every field a tool takes is a string, as the manifest describes it.
  defp answer(tool, input, assigns, actor) do
    if is_map(input) and Enum.all?(Map.values(input), &is_binary/1),
      do: answer_on_page(tool, input, assigns, actor),
      else: refusal("invalid_input", "Send an object of named fields, each a string.", fix())
  end

  defp answer_on_page(tool, input, %{room: %{fleet_id: _, slug: _} = room}, actor)
       when tool in @room_tools,
       do: room_tool(tool, input, room, actor)

  defp answer_on_page(tool, input, %{key_profile: %{issued?: true} = key}, actor)
       when tool in @key_tools,
       do: key_tool(tool, input, key, actor)

  defp answer_on_page(_tool, _input, _assigns, _actor),
    do:
      refusal(
        "not_on_page",
        "This page doesn't show that now.",
        "Check what the page shows, then call again."
      )

  defp room_tool("list_rooms", _input, %{fleet_id: fleet_id}, actor) do
    rooms = Rooms.list_rooms!(fleet_id, actor: actor)
    %{ok: true, fleet_id: fleet_id, rooms: Enum.map(rooms, &RoomJSON.room/1)}
  end

  # Another of the fleet's rooms may be read by its slug. Posts written as a
  # key the person has muted are left out, as the page leaves them out, and
  # the cursor still counts them.
  defp room_tool("read_room", input, %{fleet_id: fleet_id, slug: shown}, actor) do
    slug = Map.get(input, "slug", shown)

    with {:ok, messages} <-
           Rooms.read_messages(fleet_id, slug, Map.take(input, ["after_seq", "limit"]),
             actor: actor
           ),
         %{} = room <- Rooms.get_room!(fleet_id, slug, actor: actor) do
      %{
        ok: true,
        room: RoomJSON.room(room),
        cursor: cursor(messages, input),
        has_more: Rooms.more_after?(messages),
        messages:
          messages
          |> Rooms.unmuted(Rooms.muted_keys!(fleet_id, actor))
          |> Enum.map(&RoomJSON.message/1)
      }
    else
      nil -> room_unknown()
      {:error, error} -> read_refusal(error)
    end
  end

  defp room_tool("post_to_room", %{"body" => body}, %{fleet_id: fleet_id, slug: slug}, actor) do
    %{fleet_id: fleet_id, slug: slug, body: body, idempotency_key: Ash.UUID.generate()}
    |> Rooms.send_message(actor: actor)
    |> posted(fleet_id, actor)
  end

  # Only someone signed in has mutes, as only they are shown Mute.
  defp room_tool(tool, %{"key" => key}, %{fleet_id: fleet_id}, actor)
       when tool in ["mute_key", "unmute_key"] do
    with muter when is_binary(muter) <- Muter.of(actor),
         {:ok, token_id} <- key_number(key),
         {:ok, _mute} <- change_mute(tool, fleet_id, token_id, actor) do
      fleet_id
      |> RoomJSON.mutes(Rooms.mutes_in_fleet!(fleet_id, actor: actor))
      |> Map.put(:ok, true)
    else
      nil -> sign_in_required()
      :error -> refusal("invalid_input", "key is a Key's number, such as 42.", fix())
      {:error, error} -> raise error
    end
  end

  defp room_tool(_tool, _input, _room, _actor),
    do: refusal("invalid_input", "A required field is missing.", fix())

  defp key_tool("read_key_thread", input, %{fleet_id: fleet_id, token_id: token_id}, actor) do
    case Rooms.read_key_thread(fleet_id, token_id, Map.take(input, ["after_seq", "limit"]),
           actor: actor
         ) do
      {:ok, messages} ->
        thread = Rooms.get_key_thread!(fleet_id, token_id, actor: actor)

        %{
          ok: true,
          thread: %{token_id: token_id, head_seq: if(thread, do: thread.head_seq, else: 0)},
          cursor: cursor(messages, input),
          has_more: Rooms.more_after?(messages),
          messages:
            messages
            |> Rooms.unmuted(Rooms.muted_keys!(fleet_id, actor))
            |> Enum.map(&RoomJSON.message/1)
        }

      {:error, error} ->
        read_refusal(error)
    end
  end

  defp key_tool("post_to_key_thread", %{"body" => body}, key, actor) do
    %{
      fleet_id: key.fleet_id,
      token_id: key.token_id,
      body: body,
      idempotency_key: Ash.UUID.generate()
    }
    |> Rooms.send_to_key(actor: actor)
    |> posted(key.fleet_id, actor)
  end

  defp key_tool(_tool, _input, _key, _actor),
    do: refusal("invalid_input", "A required field is missing.", fix())

  # The read has already taken after_seq as a whole number.
  defp cursor([], input), do: input |> Map.get("after_seq", "0") |> String.to_integer()
  defp cursor(messages, _input), do: List.last(messages).seq

  defp key_number(key) do
    case Integer.parse(key) do
      {token_id, ""} when token_id > 0 and token_id <= @max_token_id -> {:ok, token_id}
      _other -> :error
    end
  end

  defp change_mute("mute_key", fleet_id, token_id, actor),
    do: Rooms.mute_key(fleet_id, token_id, actor: actor)

  defp change_mute("unmute_key", fleet_id, token_id, actor),
    do: Rooms.unmute_key(fleet_id, token_id, actor: actor)

  defp posted({:ok, message}, _fleet_id, _actor),
    do: %{ok: true, message: RoomJSON.message(message)}

  defp posted({:error, %Ash.Error.Forbidden{}}, _fleet_id, nil), do: sign_in_required()

  # Standing cannot be read while the fleet's key ownership is not fresh.
  defp posted({:error, %Ash.Error.Forbidden{}}, fleet_id, _actor) do
    if Chain.fresh?(fleet_id),
      do:
        refusal(
          "not_a_member",
          "Only the people and agents holding this fleet’s Keys, or a shard of one, can post here. Nothing was posted.",
          "Everyone can read. The person signed in needs a Key in this fleet, or a shard of one, to post."
        ),
      else:
        refusal(
          "ownership_refreshing",
          KeysLive.refreshing(),
          "Nothing was posted. Call again in a moment."
        )
  end

  defp posted({:error, error}, _fleet_id, _actor) do
    cond do
      room_unknown?(error) ->
        room_unknown()

      too_many = post_limit(error) ->
        refusal(
          "post_limit_reached",
          RoomsLive.post_limit(too_many) <> " Nothing was posted.",
          "Call again after retry_after seconds."
        )
        |> put_in([:error, :retry_after], too_many.retry_after)

      true ->
        refusal(
          "invalid_message",
          "A post is 1 to 4,000 characters. Nothing was posted.",
          "Correct it, then call again."
        )
    end
  end

  defp post_limit(%Ash.Error.Invalid{errors: errors}),
    do: Enum.find(errors, &match?(%PostLimitError{}, &1))

  defp post_limit(_error), do: nil

  defp read_refusal(error) do
    if room_unknown?(error),
      do: room_unknown(),
      else:
        refusal(
          "invalid_input",
          "after_seq is a whole number from 0, and limit a whole number from 1 to 200.",
          fix()
        )
  end

  defp room_unknown?(%RoomUnknownError{}), do: true

  defp room_unknown?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%RoomUnknownError{}, &1))

  defp room_unknown?(_error), do: false

  defp room_unknown,
    do:
      refusal(
        "room_unknown",
        "This fleet has no room with that address.",
        "list_rooms names the fleet's rooms."
      )

  defp sign_in_required,
    do:
      refusal(
        "sign_in_required",
        "No one is signed in on this page, so nothing was changed.",
        "Ask the person to sign in, then call again."
      )

  defp fix, do: "Fix the call, then call again."

  defp refusal(code, message, hint),
    do: %{ok: false, error: %{code: code, message: message, hint: hint}}
end
