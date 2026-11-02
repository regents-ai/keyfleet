defmodule Keyfleet.Points.Message do
  @moduledoc """
  Regent Points' check of a person's first message (`keyfleet.first_message`):
  a post written as their Key in a room or a Key's thread, or a direct
  message their Key sent, by them or an agent paired with them. A post
  written as no Key, in the People and agents room, earns nothing.
  """

  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"source_kind" => "room_post", "source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(Keyfleet.Rooms.Message, id) do
      nil ->
        {:error, :message_not_found}

      %{as_key: nil} ->
        {:error, :message_not_as_key}

      post ->
        with {:ok, holder} <- Holder.at(post.fleet_id, post.as_key, post.inserted_at),
             {:ok, actor} <- Holder.actor(holder, post.agent_pairing_id),
             do: {:ok, Holder.facts("room_post", id, holder, actor, post.inserted_at)}
    end
  end

  def verify(%{"source_kind" => "direct_message", "source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(Keyfleet.Dms.Message, id) do
      nil ->
        {:error, :message_not_found}

      message ->
        with {:ok, holder} <-
               Holder.of_epoch(
                 message.fleet_id,
                 message.from_token_id,
                 message.from_ownership_epoch,
                 message.inserted_at
               ),
             {:ok, actor} <- Holder.actor(holder, message.agent_pairing_id),
             do: {:ok, Holder.facts("direct_message", id, holder, actor, message.inserted_at)}
    end
  end
end
