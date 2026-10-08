defmodule Keyfleet.Rooms.Preparations.OneRoom do
  @moduledoc """
  Reads one room's posts, oldest first and never more than the reader asked
  for, whatever a caller tried to add to the query.

  With `in: :room` the room is the fleet's room named by `slug`; with
  `in: :key` it is the thread of the key `token_id`. A room the fleet does not
  have, or a thread nobody has written to yet, reads as a room with nothing
  in it.

  One post more than asked for is read, and left out, so each post answered
  carries `more_after` in its metadata: whether the room has a post after it.
  `Keyfleet.Rooms.more_after?/1` reads it from the last post answered.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias Keyfleet.Rooms

  @impl true
  def prepare(query, opts, context) do
    Ash.Query.before_action(query, fn query ->
      query =
        case room(query, Keyword.fetch!(opts, :in), context.actor) do
          nil -> Ash.Query.do_filter(query, false)
          %{id: room_id} -> Ash.Query.filter(query, room_id == ^room_id)
        end

      query
      |> Ash.Query.unset([:sort, :limit, :offset])
      |> Ash.Query.sort(seq: :asc)
      |> Ash.Query.limit(Ash.Query.get_argument(query, :limit) + 1)
    end)
    |> Ash.Query.after_action(fn query, posts ->
      {page, rest} = Enum.split(posts, Ash.Query.get_argument(query, :limit))
      last = length(page) - 1

      {:ok,
       page
       |> Enum.with_index()
       |> Enum.map(fn {post, i} ->
         Ash.Resource.put_metadata(post, :more_after, i < last or rest != [])
       end)}
    end)
  end

  defp room(query, :room, actor),
    do:
      Rooms.get_room!(
        Ash.Query.get_argument(query, :fleet_id),
        Ash.Query.get_argument(query, :slug),
        actor: actor
      )

  defp room(query, :key, actor),
    do:
      Rooms.get_key_thread!(
        Ash.Query.get_argument(query, :fleet_id),
        Ash.Query.get_argument(query, :token_id),
        actor: actor
      )
end
