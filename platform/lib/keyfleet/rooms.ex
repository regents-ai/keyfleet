defmodule Keyfleet.Rooms do
  @moduledoc """
  Fleet-scoped rooms for native chat, a public thread for every key, and each
  reader's own mutes of the keys whose posts they would rather not see.
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Rooms.Checks.RoomPoster
  alias Keyfleet.Rooms.Errors.RoomUnknownError
  alias Keyfleet.Rooms.Muter
  alias Keyfleet.Rooms.Room

  # As many rooms as a fleet holds: five fixed rooms, five open rooms and a
  # hundred created ones.
  @max_sync_rooms 110
  @sync_page 50
  @graph_sync_page 100
  # Places in a room are counted in a Postgres bigint.
  @max_seq 9_223_372_036_854_775_807

  resources do
    resource Keyfleet.Rooms.Room do
      define :list_rooms, action: :for_fleet, args: [:fleet_id]
      define :get_room, action: :in_fleet, args: [:fleet_id, :slug], not_found_error?: false
      define :create_room, action: :create
      define :set_room_topic, action: :set_topic, args: [:topic]

      define :get_key_thread,
        action: :key_thread,
        args: [:fleet_id, :token_id],
        not_found_error?: false

      define :open_key_thread, action: :open_key_thread, args: [:fleet_id, :token_id]
    end

    resource Keyfleet.Rooms.Message do
      define :send_message, action: :send_message
      define :note_room_named, action: :note_room_named
      define :read_messages, action: :read_messages, args: [:fleet_id, :slug]
      define :catch_up, action: :catch_up, args: [:fleet_id, :slugs, :after_seqs, :limit]
      define :send_to_key, action: :send_to_key
      define :read_key_thread, action: :read_key_thread, args: [:fleet_id, :token_id]
      define :posts_as_key, action: :posts_as_key, args: [:fleet_id, :token_id]
      define :recent_posts, action: :recent_in_fleet, args: [:fleet_id]

      define :fleet_lines_before,
        action: :fleet_lines_before,
        args: [:fleet_id, :before_at, :before_id, :limit]

      define :get_post_in_room,
        action: :in_room,
        args: [:fleet_id, :id, :room_id],
        not_found_error?: false

      define :get_post_under_send_key,
        action: :under_send_key,
        args: [:fleet_id, :author_wallets, :idempotency_key],
        not_found_error?: false
    end

    resource Keyfleet.Rooms.Mute do
      define :mute_key, action: :mute, args: [:fleet_id, :token_id]
      define :unmute, action: :unmute
      define :mutes_in_fleet, action: :in_fleet, args: [:fleet_id]
      define :get_mute, action: :of_key, args: [:fleet_id, :token_id], not_found_error?: false
    end
  end

  @doc """
  Takes away `actor`'s mute of a key, if it has one: `{:ok, mute | nil}`.
  Unmuting a key that isn't muted changes nothing.
  """
  def unmute_key(fleet_id, token_id, opts) do
    case get_mute(fleet_id, token_id, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, mute} -> with :ok <- unmute(mute, opts), do: {:ok, mute}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The keys `actor` has muted in the fleet, as a set of key numbers; none for
  anyone not signed in.
  """
  def muted_keys!(fleet_id, actor) do
    if Muter.of(actor),
      do: fleet_id |> mutes_in_fleet!(actor: actor) |> MapSet.new(& &1.token_id),
      else: MapSet.new()
  end

  @doc """
  `messages` without the posts written as a key in `muted`. How far a reader
  has got is always counted over every message, shown or not.
  """
  def unmuted(messages, muted),
    do: Enum.reject(messages, &(&1.kind == :post and MapSet.member?(muted, &1.as_key)))

  @doc """
  Where the fleet's rooms, posts and keys' threads publish what changed in
  them: "room_head", "key_activity" and "rooms_changed".
  """
  def fleet_topic(fleet_id), do: "fleet:#{fleet_id}:rooms"

  @doc """
  Whether posts wait after the last of `posts`, a page read with
  `read_messages` or `read_key_thread`. Nothing read means nothing waits.
  """
  def more_after?([]), do: false
  def more_after?(posts), do: posts |> List.last() |> Ash.Resource.get_metadata(:more_after)

  @doc """
  Everything one caller has not read yet across the rooms it names and the
  fleet's workspace.

  Each entry of `cursors` is a `%{slug: slug, after_seq: seq}` saying how far the
  caller has read that room. Every room the caller may read answers with the
  posts after that point, the cursor those posts reach, and the room's own
  head, so a caller that is behind knows to come back for the rest. A room
  only the fleet's keys read, named by a caller without one, answers with its
  slug alone and `refused: true`, and the rest of the answer stands. A caller
  that names rooms and may read none of them is refused (`Ash.Error.Forbidden`).

  `graph_after_seq` says how far the caller has read the workspace's log. The
  workspace answers with at most 100 of its changes after that point, as
  `Keyfleet.Graph.list_changes/3` does, with `next_cursor` to send next time and
  `run_id`: a different `run_id` from the one the caller last saw means the log
  started over, and the caller reads it again from 0.

  `proposals_after_seq` says how far the caller has read the fleet's proposal
  records. Proposals answer with the ones changed after that point, as
  `Keyfleet.Proposals.changes/2` does.

  `dms_after_seq`, when it is not nil, says how far the caller has read its
  Keys' direct messages, which then answer as `Keyfleet.Dms.changes/3` does:
  the messages to or from every Key the caller holds now. With nil, `dms` is
  nil and direct messages are not followed.

  Something new, or more waiting, is answered at once, and so is everything
  when `wait?` is false. Otherwise the caller is answered as soon as the fleet
  announces a workspace change, a proposal change, a post past the caller's
  place in a room it follows or a direct message past its place, or after
  `:agent_wait_ms` with nothing, and asks again straight away. The
  announcements only say when to read again: everything the caller gets is
  read as the caller. Nothing is marked as read, and asking again is always
  safe.
  """
  def sync(fleet_id, cursors, graph_after_seq, proposals_after_seq, dms_after_seq, actor, wait?) do
    read = fn ->
      read_sync(fleet_id, cursors, graph_after_seq, proposals_after_seq, dms_after_seq, actor)
    end

    if wait?,
      do: wait_for_news(fleet_id, inbox_topics(fleet_id, dms_after_seq, actor), read),
      else: read.()
  end

  defp read_sync(fleet_id, cursors, graph_after_seq, proposals_after_seq, dms_after_seq, actor) do
    # The workspace is read first, since it answers for a fleet outside the catalog.
    with :ok <- validate_cursors(cursors),
         :ok <- in_log(graph_after_seq),
         :ok <- in_log(proposals_after_seq),
         {:ok, graph} <-
           Keyfleet.Graph.list_changes(
             fleet_id,
             %{after_seq: graph_after_seq, limit: @graph_sync_page},
             actor: actor
           ),
         {:ok, rooms} <- sync_rooms(fleet_id, cursors, actor),
         {:ok, dms} <- sync_dms(fleet_id, dms_after_seq, actor) do
      proposals = Keyfleet.Proposals.changes(fleet_id, proposals_after_seq)
      {:ok, %{rooms: rooms, graph: graph, proposals: proposals, dms: dms}}
    end
  end

  # Direct messages are followed only when asked for.
  defp sync_dms(_fleet_id, nil, _actor), do: {:ok, nil}
  defp sync_dms(fleet_id, after_seq, actor), do: Keyfleet.Dms.changes(fleet_id, after_seq, actor)

  defp inbox_topics(_fleet_id, nil, _actor), do: []
  defp inbox_topics(fleet_id, _after_seq, actor), do: Keyfleet.Dms.inbox_topics(fleet_id, actor)

  defp news?(%{rooms: rooms, graph: graph, proposals: proposals, dms: dms}),
    do:
      graph.events != [] or graph.has_more or proposals.items != [] or proposals.has_more or
        Enum.any?(rooms, &room_news?/1) or dm_news?(dms)

  # A refused room answers with its slug alone, so it never brings news.
  defp room_news?(%{refused: true}), do: false
  defp room_news?(room), do: room.messages != [] or room.cursor < room.head_seq

  # Direct messages not asked for never bring news.
  defp dm_news?(nil), do: false
  defp dm_news?(dms), do: dms.messages != [] or dms.has_more

  # Subscribed before the first read, so nothing announced between that read
  # and the wait is missed.
  defp wait_for_news(fleet_id, inbox_topics, read) do
    topics = [
      fleet_topic(fleet_id),
      Keyfleet.Graph.head_topic(fleet_id),
      Keyfleet.Proposals.topic(fleet_id) | inbox_topics
    ]

    Enum.each(topics, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))

    try do
      with {:ok, synced} <- read.() do
        if news?(synced),
          do: {:ok, synced},
          else:
            await_news(fleet_id, read, synced, System.monotonic_time(:millisecond) + wait_ms())
      end
    after
      Enum.each(topics, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
      flush_news(fleet_id)
    end
  end

  # A new run or watermark of the workspace is answered whatever it brings, as
  # the caller tells a log that started over by its `run_id`. A post is read
  # only when it is past the caller's place in a room it follows, and a direct
  # message only when it is past the caller's place in them; either is answered
  # once that read has something new. The fleet's other announcements bring the
  # caller nothing.
  # A steady run of other announcements must not hold the caller past its
  # deadline, so the time left is read before every wait.
  defp await_news(fleet_id, read, synced, until) do
    case until - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:ok, synced}

      left ->
        receive do
          {:graph_head, ^fleet_id, _run_id, _watermark} ->
            read.()

          {:proposals_changed, ^fleet_id} ->
            read.()

          %Phoenix.Socket.Broadcast{event: "room_head", payload: %{room_id: room_id, seq: seq}} ->
            if Enum.any?(
                 synced.rooms,
                 &match?(%{room_id: ^room_id, cursor: cursor} when seq > cursor, &1)
               ),
               do: read_again(fleet_id, read, until),
               else: await_news(fleet_id, read, synced, until)

          %Phoenix.Socket.Broadcast{event: "dm_head", payload: %{seq: seq}} ->
            if match?(%{next_cursor: cursor} when seq > cursor, synced.dms),
              do: read_again(fleet_id, read, until),
              else: await_news(fleet_id, read, synced, until)

          %Phoenix.Socket.Broadcast{} ->
            await_news(fleet_id, read, synced, until)
        after
          left -> {:ok, synced}
        end
    end
  end

  defp read_again(fleet_id, read, until) do
    case read.() do
      {:ok, again} ->
        if news?(again), do: {:ok, again}, else: await_news(fleet_id, read, again, until)

      error ->
        error
    end
  end

  # A connection kept open for the next request must not carry this wait's
  # announcements into it.
  defp flush_news(fleet_id) do
    receive do
      {:graph_head, ^fleet_id, _run_id, _watermark} -> flush_news(fleet_id)
      {:proposals_changed, ^fleet_id} -> flush_news(fleet_id)
      %Phoenix.Socket.Broadcast{} -> flush_news(fleet_id)
    after
      0 -> :ok
    end
  end

  defp wait_ms, do: Application.fetch_env!(:keyfleet, :agent_wait_ms)

  # Every room named must be one the fleet has, whoever asks, since every
  # room's name is public. Which of them the caller may read is decided once,
  # from its standing read once. The posts are then read before the heads. A
  # post is only ever seen once its room has counted it, so a head read
  # afterwards is never behind the posts it is returned with.
  defp sync_rooms(fleet_id, cursors, actor) do
    standing = RoomPoster.standing(actor, fleet_id)
    rooms = Map.new(list_rooms!(fleet_id, actor: actor), &{&1.slug, &1})

    with :ok <- known_rooms(fleet_id, cursors, rooms),
         {readable, refused} = Enum.split_with(cursors, &readable?(rooms[&1.slug], standing)),
         :ok <- some_readable(readable, refused),
         {:ok, posts} <- catch_up_rooms(fleet_id, readable, actor, standing) do
      heads = Map.new(list_rooms!(fleet_id, actor: actor), &{&1.slug, &1})
      synced = Map.new(readable, &{&1.slug, synced(&1, heads[&1.slug], posts)})

      refused = MapSet.new(refused, & &1.slug)

      {:ok,
       Enum.map(cursors, fn %{slug: slug} ->
         if MapSet.member?(refused, slug), do: %{slug: slug, refused: true}, else: synced[slug]
       end)}
    end
  end

  defp known_rooms(fleet_id, cursors, rooms) do
    case Enum.find(cursors, &(not Map.has_key?(rooms, &1.slug))) do
      nil -> :ok
      %{slug: slug} -> {:error, RoomUnknownError.exception(fleet_id: fleet_id, slug: slug)}
    end
  end

  # Anyone reads a public room; the fleet's keys read every room.
  defp readable?(room, standing), do: room.public or RoomPoster.standing?(standing)

  defp some_readable([], [_ | _]), do: {:error, Ash.Error.Forbidden.exception([])}
  defp some_readable(_readable, _refused), do: :ok

  # The posts of every readable room named are read together, in one query,
  # and grouped by room.
  defp catch_up_rooms(_fleet_id, [], _actor, _standing), do: {:ok, %{}}

  defp catch_up_rooms(fleet_id, cursors, actor, standing) do
    slugs = Enum.map(cursors, & &1.slug)
    after_seqs = Enum.map(cursors, & &1.after_seq)

    with {:ok, posts} <-
           catch_up(fleet_id, slugs, after_seqs, @sync_page, actor: actor, context: standing),
         do: {:ok, Enum.group_by(posts, & &1.room_id)}
  end

  defp synced(%{slug: slug, after_seq: after_seq}, room, posts) do
    %{id: room_id, kind: kind, head_seq: head_seq} = room
    messages = Map.get(posts, room_id, [])

    cursor =
      case List.last(messages) do
        nil -> after_seq
        last -> last.seq
      end

    %{
      room_id: room_id,
      slug: slug,
      kind: kind,
      head_seq: head_seq,
      cursor: cursor,
      messages: messages
    }
  end

  # One entry per room, each saying how far along that room the caller has read.
  defp validate_cursors(cursors) when is_list(cursors) do
    valid? =
      length(cursors) <= @max_sync_rooms and
        Enum.all?(cursors, fn
          %{slug: slug, after_seq: after_seq} -> is_binary(slug) and after_seq in 0..@max_seq
          _cursor -> false
        end) and
        cursors |> Enum.uniq_by(& &1.slug) |> length() == length(cursors)

    if valid?, do: :ok, else: {:error, :invalid_request}
  end

  defp validate_cursors(_cursors), do: {:error, :invalid_request}

  defp in_log(after_seq) when after_seq in 0..@max_seq, do: :ok
  defp in_log(_after_seq), do: {:error, :invalid_request}

  @doc """
  Names one of the fleet's open rooms, or names it again, as `actor`.

  The room takes a line saying who named it and what, and answers with its new
  topic, who set it and when. A room the fleet does not have is
  `RoomUnknownError`; a room that is not open is refused as invalid.
  """
  def name_open_room(fleet_id, slug, topic, opts) do
    case get_room(fleet_id, slug, opts) do
      {:ok, nil} -> {:error, RoomUnknownError.exception(fleet_id: fleet_id, slug: slug)}
      {:ok, room} -> set_room_topic(room, topic, opts)
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Whether `refusal` says another room of the fleet already has this `field`:
  its address (`:slug`), or the name it goes by (`:name`), which is where a
  clash is reported whether it came from naming a room or creating one.
  """
  def taken?(%Ash.Error.Invalid{errors: errors}, field),
    do: Enum.any?(errors, &taken_on?(&1, field))

  def taken?(_refusal, _field), do: false

  defp taken_on?(%Ash.Error.Changes.InvalidAttribute{field: field, private_vars: vars}, field),
    do: Keyword.get(vars || [], :constraint_type) == :unique

  defp taken_on?(_error, _field), do: false

  @doc "How many rooms agents have created in the fleet."
  def count_created_rooms!(fleet_id) do
    Room
    |> Ash.Query.for_read(:for_fleet, %{fleet_id: fleet_id})
    |> Ash.Query.filter(kind == :created)
    |> Ash.count!()
  end

  @doc """
  Ensures the five fixed rooms and the five open rooms of each fleet in
  `fleet_ids` from trusted setup code. The fleets must already be seeded.

  Reruns preserve room identities, restore canonical names and leave every open
  room's topic as members named it. The whole bootstrap commits together. This
  internal entry point must never be exposed as a user action.
  """
  def bootstrap_rooms!(fleet_ids) do
    inputs =
      for fleet_id <- fleet_ids, {slug, name, kind} <- Room.own_rooms() do
        %{fleet_id: fleet_id, slug: slug, name: name, kind: kind}
      end

    %Ash.BulkResult{records: rooms} =
      Ash.bulk_create!(inputs, Room, :bootstrap,
        actor: %Keyfleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    rooms
  end
end
