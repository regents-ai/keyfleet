defmodule Keyfleet.Rooms do
  @moduledoc "Fleet-scoped rooms for native chat, and a public thread for every key."
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Rooms.Errors.RoomUnknownError
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

      define :get_post_in_room, action: :in_room, args: [:id, :room_id], not_found_error?: false

      define :get_post_under_send_key,
        action: :under_send_key,
        args: [:fleet_id, :author_wallets, :idempotency_key],
        not_found_error?: false
    end
  end

  @doc "Where a fleet says that one of its rooms has taken a new post."
  def fleet_topic(fleet_id), do: "fleet:#{fleet_id}:rooms"

  @doc """
  Everything one caller has not read yet across the rooms it names and the
  fleet's workspace.

  Each entry of `cursors` is a `%{slug: slug, after_seq: seq}` saying how far the
  caller has read that room. Every room answers with the posts after that point,
  the cursor those posts reach, and the room's own head, so a caller that is
  behind knows to come back for the rest.

  `graph_after_seq` says how far the caller has read the workspace's log. The
  workspace answers with at most 100 of its changes after that point, as
  `Keyfleet.Graph.list_changes/3` does, with `next_cursor` to send next time and
  `run_id`: a different `run_id` from the one the caller last saw means the log
  started over, and the caller reads it again from 0.

  `proposals_after_seq` says how far the caller has read the fleet's proposal
  records. Proposals answer with the ones changed after that point, as
  `Keyfleet.Proposals.changes/3` does.

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
      proposals = Keyfleet.Proposals.changes(fleet_id, proposals_after_seq, DateTime.utc_now())

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
    if graph.has_more or proposals.has_more or Enum.any?(rooms, &(&1.cursor < &1.head_seq)),
      do: 0,
      else: Enum.random(15..30)
  end

  # The posts are read before the heads. A post is only ever seen once its room
  # has counted it, so a head read afterwards is never behind the posts it is
  # returned with.
  defp sync_rooms(fleet_id, cursors, actor) do
    read =
      Enum.map(cursors, fn cursor ->
        {cursor,
         read_messages!(fleet_id, cursor.slug, %{after_seq: cursor.after_seq, limit: @sync_page},
           actor: actor
         )}
      end)

    rooms = Map.new(list_rooms!(fleet_id, actor: actor), &{&1.slug, &1})

    case Enum.find(cursors, &(not Map.has_key?(rooms, &1.slug))) do
      nil ->
        {:ok, Enum.map(read, fn {cursor, messages} -> synced(cursor, messages, rooms) end)}

      %{slug: slug} ->
        {:error, RoomUnknownError.exception(fleet_id: fleet_id, slug: slug)}
    end
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

  @doc "Tells everyone watching the fleet's rooms that its list of rooms has changed."
  def rooms_changed(fleet_id) do
    Phoenix.PubSub.broadcast(Keyfleet.PubSub, fleet_topic(fleet_id), {:rooms_changed, fleet_id})
  end

  @doc """
  Ensures the five fixed rooms and the five open rooms of every persisted fleet
  from trusted setup code.

  Reruns preserve room identities, restore canonical names and leave every open
  room's topic as members named it. The whole bootstrap commits together. This
  internal entry point must never be exposed as a user action.
  """
  def bootstrap_rooms! do
    fleets = Keyfleet.Fleets.list_fleets!() |> Enum.sort_by(& &1.id)

    if not match?([_, _, _, _], fleets) do
      raise "Room bootstrap requires the complete fixed fleet catalog"
    end

    inputs =
      for fleet <- fleets, {slug, name, kind} <- Room.own_rooms() do
        %{fleet_id: fleet.id, slug: slug, name: name, kind: kind}
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
