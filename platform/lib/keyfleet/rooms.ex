defmodule KeyFleet.Rooms do
  @moduledoc "Fleet-scoped rooms for native chat."
  use Ash.Domain

  alias KeyFleet.Rooms.Errors.RoomUnknownError

  @core_rooms [{"general", "General"}, {"planning", "Planning"}, {"work", "Work"}]
  @max_sync_rooms 100
  @sync_page 50
  @graph_sync_page 100
  # Places in a room are counted in a Postgres bigint.
  @max_seq 9_223_372_036_854_775_807

  resources do
    resource KeyFleet.Rooms.Room do
      define :list_rooms, action: :for_fleet, args: [:fleet_id]
      define :get_room, action: :in_fleet, args: [:fleet_id, :slug], not_found_error?: false
    end

    resource KeyFleet.Rooms.Message do
      define :send_message, action: :send_message
      define :read_messages, action: :read_messages, args: [:fleet_id, :slug]

      define :get_post_in_room, action: :in_room, args: [:id, :room_id], not_found_error?: false

      define :get_post_under_send_key,
        action: :under_send_key,
        args: [:fleet_id, :author_wallet, :idempotency_key],
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
  `KeyFleet.Graph.list_changes/3` does, with `next_cursor` to send next time and
  `run_id`: a different `run_id` from the one the caller last saw means the log
  started over, and the caller reads it again from 0.

  `next_poll_seconds` is when to ask again: at once while anything has more
  waiting, otherwise between 15 and 30 seconds, spread so callers do not all
  come back together. Nothing is marked as read, and asking again is always
  safe.

  `proposals` is answered empty here; fleet decisions arrive in a later slice and
  share this one call rather than adding a second.
  """
  def sync(fleet_id, cursors, graph_after_seq, actor) do
    # The workspace is read first, since it answers for a fleet outside the catalog.
    with :ok <- validate_cursors(cursors),
         :ok <- in_log(graph_after_seq),
         {:ok, graph} <-
           KeyFleet.Graph.list_changes(
             fleet_id,
             %{after_seq: graph_after_seq, limit: @graph_sync_page},
             actor: actor
           ),
         {:ok, rooms} <- sync_rooms(fleet_id, cursors, actor) do
      {:ok,
       %{
         rooms: rooms,
         graph: graph,
         proposals: [],
         next_poll_seconds: next_poll_seconds(rooms, graph)
       }}
    end
  end

  defp next_poll_seconds(rooms, graph) do
    if graph.has_more or Enum.any?(rooms, &(&1.cursor < &1.head_seq)),
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

    heads = Map.new(list_rooms!(fleet_id, actor: actor), &{&1.slug, &1.head_seq})

    case Enum.find(cursors, &(not Map.has_key?(heads, &1.slug))) do
      nil ->
        {:ok, Enum.map(read, fn {cursor, messages} -> synced(cursor, messages, heads) end)}

      %{slug: slug} ->
        {:error, RoomUnknownError.exception(fleet_id: fleet_id, slug: slug)}
    end
  end

  defp synced(%{slug: slug, after_seq: after_seq}, messages, heads) do
    cursor =
      case List.last(messages) do
        nil -> after_seq
        last -> last.seq
      end

    %{slug: slug, head_seq: heads[slug], cursor: cursor, messages: messages}
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
  Ensures the three core rooms for every persisted fleet from trusted setup code.

  Reruns preserve room identities and restore canonical names. The whole bootstrap
  commits together. This internal entry point must never be exposed as a user action.
  """
  def bootstrap_core_rooms! do
    fleets = KeyFleet.Fleets.list_fleets!() |> Enum.sort_by(& &1.id)

    if not match?([_, _, _, _], fleets) do
      raise "Core room bootstrap requires the complete fixed fleet catalog"
    end

    inputs =
      for fleet <- fleets, {slug, name} <- @core_rooms do
        %{fleet_id: fleet.id, slug: slug, name: name}
      end

    %Ash.BulkResult{records: rooms} =
      Ash.bulk_create!(inputs, KeyFleet.Rooms.Room, :bootstrap,
        actor: %KeyFleet.Actors.System{},
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        sorted?: true
      )

    rooms
  end
end
