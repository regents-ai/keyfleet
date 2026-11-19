defmodule Keyfleet.Points.RoomPost do
  @moduledoc """
  Regent Points' check of a post a Key made (`Keyfleet.Rooms.Message`), keyed
  by its id. A post is written as its author's Key (`as_key`); it earns for
  the account that held that Key when it was written
  (`Keyfleet.Points.Holder`), when that person wrote it or an agent paired
  with them did.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Points.Holder
  alias Keyfleet.Rooms

  def verify(%{"source_event_key" => id}) do
    case Rooms.get_post(id, actor: %System{}) do
      {:ok, %{} = post} -> posted(id, post)
      {:ok, nil} -> {:error, :post_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp posted(id, post) do
    at = post.inserted_at

    with {:ok, epoch} <- Holder.epoch_at(post.fleet_id, post.as_key, at),
         {:ok, holder} <- Holder.holder(epoch, at),
         {:ok, actor} <- Holder.actor(holder, Holder.acting(post, post.author_wallet), at) do
      Holder.facts("room_post", id, holder, actor, at)
    end
  end
end
