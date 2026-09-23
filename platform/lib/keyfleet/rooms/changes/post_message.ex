defmodule KeyFleet.Rooms.Changes.PostMessage do
  @moduledoc """
  Puts one line in its room, of the kind the action names (`kind: :post` or
  `kind: :room_named`), or hands back the line this sender already made.

  A sender names every post with a key of its own. If the same key arrives again
  with the same words, the room keeps the post it already has and answers with
  it; the same key with different words is a mistake and is refused, so a sender
  that never heard the answer can simply ask again.
  """
  use Ash.Resource.Change

  alias KeyFleet.Actors.Agent
  alias KeyFleet.Actors.Human
  alias KeyFleet.Rooms
  alias KeyFleet.Rooms.Errors.ReplyOutsideRoomError
  alias KeyFleet.Rooms.Errors.RoomUnknownError
  alias KeyFleet.Rooms.Errors.SendConflictError
  alias KeyFleet.Rooms.Sequence

  @impl true
  def change(changeset, opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.before_action(&place(&1, actor, Keyword.fetch!(opts, :kind)))
    |> Ash.Changeset.after_action(&confirm/2)
  end

  defp place(changeset, actor, kind) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    slug = Ash.Changeset.get_argument(changeset, :slug)
    reply_to_id = Ash.Changeset.get_argument(changeset, :reply_to_id)
    room = Rooms.get_room!(fleet_id, slug, actor: actor)

    cond do
      is_nil(room) ->
        Ash.Changeset.add_error(
          changeset,
          RoomUnknownError.exception(fleet_id: fleet_id, slug: slug)
        )

      not answers_this_room?(reply_to_id, room, actor) ->
        Ash.Changeset.add_error(
          changeset,
          ReplyOutsideRoomError.exception(reply_to_id: reply_to_id)
        )

      true ->
        write(changeset, room, actor, kind)
    end
  end

  defp answers_this_room?(nil, _room, _actor), do: true

  defp answers_this_room?(reply_to_id, room, actor),
    do: Rooms.get_post_in_room!(reply_to_id, room.id, actor: actor) != nil

  defp write(changeset, room, actor, kind) do
    Sequence.lock_room!(room.id)

    {author, profile} = author(room.fleet_id, actor)
    body = Ash.Changeset.get_argument(changeset, :body)
    idempotency_key = Ash.Changeset.get_argument(changeset, :idempotency_key)

    changeset
    |> Ash.Changeset.put_context(:author_profile, profile)
    |> Ash.Changeset.force_change_attributes(
      Map.merge(author, %{
        kind: kind,
        fleet_id: room.fleet_id,
        room_id: room.id,
        seq: seq(room, author.author_wallet, idempotency_key, actor),
        body: body,
        body_digest: digest(body),
        idempotency_key: idempotency_key,
        reply_to_id: Ash.Changeset.get_argument(changeset, :reply_to_id)
      })
    )
  end

  # A repeat keeps the place its post already holds, so the room's order stays
  # unbroken whether or not the first attempt ever reached the sender.
  defp seq(room, author_wallet, idempotency_key, actor) do
    case Rooms.get_post_under_send_key!(room.fleet_id, author_wallet, idempotency_key,
           actor: actor
         ) do
      nil -> Sequence.next!(room.id)
      message -> message.seq
    end
  end

  # The policy has already established that the actor holds or runs one of the
  # fleet's keys, so the holding wallet and the agent's own profile are there.
  defp author(fleet_id, %Human{wallet_addresses: wallets} = actor) do
    [key] =
      KeyFleet.Keys.keys_held_in_fleet!(fleet_id, wallets, actor: actor, query: [limit: 1])

    {%{author_kind: :human, author_wallet: key.owner_wallet, agent_profile_id: nil}, nil}
  end

  defp author(_fleet_id, %Agent{wallet_address: wallet} = actor) do
    profile = KeyFleet.Agents.get_my_profile!(actor: actor)
    {%{author_kind: :agent, author_wallet: wallet, agent_profile_id: profile.id}, profile}
  end

  defp digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  # The database settles which post a send key names. Whatever comes back must
  # be the post these words were meant to make, in the room they were meant for.
  defp confirm(changeset, message) do
    body = Ash.Changeset.get_argument(changeset, :body)

    if message.body_digest == digest(body) and
         message.room_id == Ash.Changeset.get_attribute(changeset, :room_id) do
      # A post is answered with its author, the way the room answers it.
      {:ok, %{message | agent_profile: changeset.context.author_profile}}
    else
      {:error,
       SendConflictError.exception(
         idempotency_key: Ash.Changeset.get_argument(changeset, :idempotency_key)
       )}
    end
  end
end
