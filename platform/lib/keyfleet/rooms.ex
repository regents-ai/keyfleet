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

  `next_poll_seconds` is when to ask again: at once while anything has more
  waiting, otherwise between 15 and 30 seconds, spread so callers do not all
  come back together. Nothing is marked as read, and asking again is always
  safe.
  """
  def sync(fleet_id, cursors, graph_after_seq, proposals_after_seq, actor) do
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
         {:ok, rooms} <- sync_rooms(fleet_id, cursors, actor) do
      proposals = Keyfleet.Proposals.changes(fleet_id, proposals_after_seq)

      {:ok,
       %{
         rooms: rooms,
         graph: graph,
         proposals: proposals,
         next_poll_seconds: next_poll_seconds(rooms, graph, proposals)
       }}
    end
  end

  defp next_poll_seconds(rooms, graph, proposals) do
    if graph.has_more or proposals.has_more or
         Enum.any?(rooms, &match?(%{cursor: cursor, head_seq: head} when cursor < head, &1)),
       do: 0,
       else: Enum.random(15..30)
  end

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
         {:ok, read} <- read_cursors(fleet_id, readable, actor, standing) do
      heads = Map.new(list_rooms!(fleet_id, actor: actor), &{&1.slug, &1})

      synced =
        Map.new(read, fn {cursor, messages} -> {cursor.slug, synced(cursor, messages, heads)} end)

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

  # The rooms are answered in the order the caller named them, so the posts
  # read are kept in any order.
  defp read_cursors(fleet_id, cursors, actor, standing) do
    Enum.reduce_while(cursors, {:ok, []}, fn cursor, {:ok, read} ->
      page = %{after_seq: cursor.after_seq, limit: @sync_page}

      case read_messages(fleet_id, cursor.slug, page, actor: actor, context: standing) do
        {:ok, messages} -> {:cont, {:ok, [{cursor, messages} | read]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp synced(%{slug: slug, after_seq: after_seq}, messages, rooms) do
    cursor =
      case List.last(messages) do
        nil -> after_seq
        last -> last.seq
      end

    %{kind: kind, head_seq: head_seq} = Map.fetch!(rooms, slug)

    %{
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
