defmodule Keyfleet.Rooms.Changes.NameRoom do
  @moduledoc """
  Names an open room and says so in the room.

  The room takes a short line saying who named it and what, in its next place,
  and keeps that line's author and time as who named the room and when. Naming
  a room what it is already called changes nothing and adds no line, so asking
  again is always safe.
  """
  use Ash.Resource.Change

  alias Keyfleet.Rooms

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    if Ash.Changeset.changing_attribute?(changeset, :topic) do
      changeset
      |> Ash.Changeset.before_action(&say_so(&1, actor))
      # The room is answered with the line counted in its head.
      |> Ash.Changeset.after_action(fn changeset, room ->
        {:ok, %{room | head_seq: changeset.context.naming_line.seq}}
      end)
    else
      changeset
    end
  end

  defp say_so(changeset, actor) do
    room = changeset.data

    case Rooms.note_room_named(
           %{
             fleet_id: room.fleet_id,
             slug: room.slug,
             body: Ash.Changeset.get_attribute(changeset, :topic),
             idempotency_key: Ash.UUID.generate()
           },
           actor: actor
         ) do
      {:ok, line} ->
        changeset
        |> Ash.Changeset.put_context(:naming_line, line)
        |> Ash.Changeset.force_change_attributes(%{
          topic_set_by: line.author_wallet,
          topic_set_at: line.inserted_at
        })

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
