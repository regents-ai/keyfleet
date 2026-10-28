defmodule KeyfleetWeb.AgentReceiptController do
  @moduledoc """
  Whether a request an agent sent ran, asked by the key it sent it with, so
  an agent whose answer never arrived learns what happened before it sends
  anything again. Nothing is written.

  One key may have made a post (its send key, `idempotency_key`), a
  workspace write (its `command_id`), or both. A post is found as a retry of
  it would be: under the agent's wallet or its person's
  (`Keyfleet.Rooms.sender_wallets/1`), answered with the post as stored, its
  words exactly as kept. A workspace write is found under the agent's own
  wallet, as whichever Key it was sent as, answered with what the write
  answered. The workspace part reads from its read tables, as every
  workspace read does: a write whose answer was lost can take a moment to
  show, and a write sent again with its command id never runs twice.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Fleets, Graph, Rooms}
  alias Keyfleet.Graph.Event
  alias KeyfleetWeb.{Refusal, RoomJSON}

  def show(conn, %{"fleet_id" => fleet_id, "idempotency_key" => key}) do
    actor = conn.assigns.agent_actor

    with %{} <- Fleets.get_fleet!(fleet_id),
         {:ok, post} <- post(fleet_id, key, actor),
         {:ok, writes} <- writes(fleet_id, key, actor) do
      receipts = List.wrap(post) ++ writes
      json(conn, %{idempotency_key: key, executed: receipts != [], receipts: receipts})
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      :refreshing -> Refusal.json(conn, 503, "ownership_refreshing")
      {:error, _error} -> Refusal.json(conn, 503, "graph_unavailable")
    end
  end

  defp post(fleet_id, key, actor) do
    with {:ok, message} when message != nil <-
           Rooms.get_post_under_send_key(fleet_id, Rooms.sender_wallets(actor), key,
             actor: actor,
             load: [:room, :agent_profile, :via_agent_profile]
           ) do
      {:ok, post_receipt(message)}
    end
  end

  defp post_receipt(%{room: %{kind: :key, token_id: token_id}} = message),
    do: %{kind: "post", room: nil, wall: token_id, message: RoomJSON.message(message)}

  defp post_receipt(%{room: room} = message),
    do: %{kind: "post", room: room.slug, wall: nil, message: RoomJSON.message(message)}

  defp writes(fleet_id, key, actor) do
    wallet = String.downcase(actor.wallet_address)

    case Graph.command_records(fleet_id, key, actor: actor) do
      {:ok, records} ->
        {:ok,
         for record <- records,
             match?({_key, "agent", ^wallet}, Event.member(record.payload["principal"])),
             do: write_receipt(record)}

      {:error, %Ash.Error.Forbidden{}} ->
        members_only(fleet_id)

      {:error, error} ->
        {:error, error}
    end
  end

  # Only the fleet's members read its workspace. An agent that isn't one
  # now has no workspace write to find, and one sent again is refused, so
  # its posts are answered alone; who the members are can't be told while
  # the fleet's key ownership is not fresh.
  defp members_only(fleet_id),
    do: if(Keyfleet.Chain.fresh?(fleet_id), do: {:ok, []}, else: :refreshing)

  defp write_receipt(record) do
    {as_key, _kind, _wallet} = Event.member(record.payload["principal"])

    %{
      kind: "workspace",
      op: record.payload["op"],
      as_key: as_key,
      seq: record.seq,
      at: record.timestamp,
      result: record.payload["result"]
    }
  end
end
