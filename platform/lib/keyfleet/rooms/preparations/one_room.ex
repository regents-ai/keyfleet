defmodule KeyFleet.Rooms.Preparations.OneRoom do
  @moduledoc """
  Reads one room's posts, oldest first and never more than the reader asked
  for, whatever a caller tried to add to the query.

  With `in: :room` the room is the fleet's room named by `slug`; with
  `in: :key` it is the thread of the key `token_id`. A room the fleet does not
  have, or a thread nobody has written to yet, reads as a room with nothing
  in it.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias KeyFleet.Rooms

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
      |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
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
