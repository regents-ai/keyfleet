defmodule Keyfleet.KeylessPosts do
  @moduledoc """
  Posts an agent wrote in the People and agents room before posting there
  needed a Key: written as no Key, from the agent's own wallet. They stay in
  the database as they were stored, and are put there the same way here.
  """

  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Message
  alias Keyfleet.Rooms.Room
  alias Keyfleet.Rooms.Sequence

  @doc "`agent`'s post in `fleet_id`'s People and agents room, written as no Key."
  def seed!(fleet_id, agent, body) do
    # A test's seed, not a caller: the room is read as stored, and anyone may
    # read this room.
    room = Rooms.get_room!(fleet_id, Room.people_slug(), authorize?: false)
    profile = Keyfleet.Agents.get_my_profile!(actor: agent)

    Ash.Seed.seed!(Message, %{
      kind: :post,
      in_key_thread: false,
      fleet_id: fleet_id,
      room_id: room.id,
      seq: Sequence.next!(room.id),
      author_kind: :agent,
      author_wallet: agent.wallet_address,
      agent_profile_id: profile.id,
      body: body,
      body_digest: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower),
      idempotency_key: Ash.UUID.generate()
    })
  end
end
