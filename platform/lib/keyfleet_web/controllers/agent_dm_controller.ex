defmodule KeyfleetWeb.AgentDmController do
  @moduledoc """
  Direct messages for signed agents (`Keyfleet.Dms`): a Key's conversations,
  reading and sending in one, deleting it or setting it to delete itself, the
  Keys it has blocked, and catching up on every Key the agent holds.

  Each request but catching up names the Key the agent acts as, which must be
  one it holds now: its own, one it holds a shard of, or its paired person's.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Dms
  alias Keyfleet.Dms.Errors.SameKeyError
  alias Keyfleet.Dms.Errors.SendLimitError
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms.Errors.KeyUnknownError
  alias Keyfleet.Rooms.Errors.NoAgentProfileError
  alias Keyfleet.Rooms.Errors.SendConflictError
  alias KeyfleetWeb.Refusal

  @message_fields [
    :id,
    :seq,
    :conversation_id,
    :from_token_id,
    :to_token_id,
    :body,
    :parts,
    :author_wallet,
    :inserted_at
  ]

  # A Key's conversations: the main inbox and, apart, those with Keys it has
  # blocked.
  def inbox(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    opts = [actor: conn.assigns.agent_actor]
    token_id = String.to_integer(token_id)

    with {:ok, main} <- Dms.inbox(fleet_id, token_id, opts),
         {:ok, blocked} <- Dms.inbox(fleet_id, token_id, %{blocked: true}, opts) do
      json(conn, %{
        conversations: Enum.map(main, &conversation_json(&1, token_id)),
        blocked_conversations: Enum.map(blocked, &conversation_json(&1, token_id))
      })
    else
      error -> refuse(conn, fleet_id, error)
    end
  end

  # The messages are read before the conversation, so the conversation
  # answered is never behind the messages answered with it.
  def read(conn, params) do
    {fleet_id, token_id, other} = keys(params)
    opts = [actor: conn.assigns.agent_actor]
    page = Map.take(params, ["after_seq", "limit"])

    with {:ok, messages} <- Dms.read_conversation(fleet_id, token_id, other, page, opts),
         {:ok, conversation} <-
           Dms.get_conversation(fleet_id, token_id, other, opts) do
      json(conn, %{
        conversation: conversation && conversation_json(conversation, token_id),
        cursor: cursor(messages, Map.get(params, "after_seq", 0)),
        has_more: Dms.more_after?(messages),
        messages: Enum.map(messages, &message_json/1)
      })
    else
      error -> refuse(conn, fleet_id, error)
    end
  end

  def send_message(conn, params) do
    {fleet_id, token_id, other} = keys(params)

    input =
      params
      |> Map.take(["body", "idempotency_key", "parts"])
      |> Map.merge(%{"fleet_id" => fleet_id, "from_token_id" => token_id, "to_token_id" => other})

    case Dms.send_dm(input, actor: conn.assigns.agent_actor, load: [:via_agent]) do
      {:ok, message} ->
        conn |> put_status(sent_status(message)) |> json(%{message: message_json(message)})

      error ->
        refuse(conn, fleet_id, error)
    end
  end

  # Deletes the conversation and every message in it, for both Keys.
  def delete(conn, params) do
    {fleet_id, token_id, other} = keys(params)
    opts = [actor: conn.assigns.agent_actor]

    with {:ok, conversation} <- conversation(fleet_id, token_id, other, opts),
         :ok <- Dms.delete_conversation(conversation, opts) do
      json(conn, %{deleted_conversation_id: conversation.id})
    else
      error -> refuse(conn, fleet_id, error)
    end
  end

  def auto_delete(conn, %{"days" => days} = params) do
    {fleet_id, token_id, other} = keys(params)
    opts = [actor: conn.assigns.agent_actor]

    with {:ok, conversation} <- conversation(fleet_id, token_id, other, opts),
         {:ok, conversation} <- Dms.set_auto_delete(conversation, days, opts) do
      json(conn, %{conversation: conversation_json(conversation, token_id)})
    else
      error -> refuse(conn, fleet_id, error)
    end
  end

  def block(conn, params) do
    {fleet_id, token_id, other} = keys(params)
    opts = [actor: conn.assigns.agent_actor]

    case Dms.block_key(fleet_id, token_id, other, opts) do
      {:ok, _block} -> blocks(conn, fleet_id, token_id, opts)
      error -> refuse(conn, fleet_id, error)
    end
  end

  def unblock(conn, params) do
    {fleet_id, token_id, other} = keys(params)
    opts = [actor: conn.assigns.agent_actor]

    case Dms.unblock_key(fleet_id, token_id, other, opts) do
      {:ok, _block} -> blocks(conn, fleet_id, token_id, opts)
      error -> refuse(conn, fleet_id, error)
    end
  end

  def blocked(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do: blocks(conn, fleet_id, String.to_integer(token_id), actor: conn.assigns.agent_actor)

  def changes(conn, %{"fleet_id" => fleet_id} = params) do
    case Dms.changes(fleet_id, key_cursors(params), conn.assigns.agent_actor) do
      {:ok, page} -> json(conn, changes_json(page))
      error -> refuse(conn, fleet_id, error)
    end
  end

  @doc """
  How far each Key's messages have been read, from a body's
  `keys: [{token_id, after_seq}]`, as `Keyfleet.Dms.changes/3` takes it.
  """
  def key_cursors(%{"keys" => keys}), do: Map.new(keys, &{&1["token_id"], &1["after_seq"]})

  @doc "A page of `Keyfleet.Dms.changes/3`, as this and a sync answer it."
  def changes_json(page),
    do: %{
      messages: Enum.map(page.messages, &message_json/1),
      keys: page.keys,
      has_more: page.has_more
    }

  defp blocks(conn, fleet_id, token_id, opts) do
    case Dms.blocks_of_key(fleet_id, token_id, opts) do
      {:ok, blocks} -> json(conn, %{blocked: Enum.map(blocks, & &1.blocked_token_id)})
      error -> refuse(conn, fleet_id, error)
    end
  end

  # The signed path admits only Key numbers, which fit the database's numbers.
  defp keys(%{"fleet_id" => fleet_id, "token_id" => token_id, "other_token_id" => other}),
    do: {fleet_id, String.to_integer(token_id), String.to_integer(other)}

  defp conversation(fleet_id, token_id, other, opts) do
    case Dms.get_conversation(fleet_id, token_id, other, opts) do
      {:ok, nil} -> :conversation_unknown
      found -> found
    end
  end

  defp cursor([], after_seq), do: after_seq
  defp cursor(messages, _after_seq), do: List.last(messages).seq

  # A repeat of a message already sent is answered with that message, and the
  # sender is told nothing new was written.
  defp sent_status(message) do
    if Ash.Resource.get_metadata(message, :upsert_skipped), do: 200, else: 201
  end

  defp conversation_json(conversation, token_id) do
    %{
      id: conversation.id,
      other_token_id: Dms.other_key(conversation, token_id),
      auto_delete_days: conversation.auto_delete_days,
      last_seq: conversation.last_seq,
      last_message: last_message_json(conversation)
    }
  end

  defp last_message_json(conversation),
    do: %{
      seq: conversation.last_seq,
      body: conversation.last_body,
      from_token_id: conversation.last_from_token_id,
      inserted_at: conversation.last_at
    }

  defp message_json(message) do
    message
    |> Map.take(@message_fields)
    |> Map.put(:via_agent, agent_profile_json(message.via_agent))
  end

  defp agent_profile_json(%Ash.NotLoaded{}), do: nil
  defp agent_profile_json(nil), do: nil

  defp agent_profile_json(profile),
    do: Map.take(profile, [:id, :name, :declared_harness, :current_status])

  defp refuse(conn, _fleet_id, :conversation_unknown),
    do: Refusal.json(conn, 404, "conversation_unknown")

  # Who holds a Key cannot be read while the fleet's key ownership is not fresh.
  defp refuse(conn, fleet_id, {:error, %Ash.Error.Forbidden{}}) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, not_holder(conn.assigns.agent_actor)),
      else: Refusal.json(conn, 503, "ownership_refreshing")
  end

  defp refuse(conn, _fleet_id, {:error, %Ash.Error.Invalid{errors: errors}}) do
    cond do
      Enum.any?(errors, &match?(%UnknownFleetError{}, &1)) ->
        Refusal.json(conn, 404, "fleet_unknown")

      unknown = Enum.find(errors, &match?(%KeyUnknownError{}, &1)) ->
        Refusal.key_unknown(conn, unknown.fleet_id, unknown.token_id)

      Enum.any?(errors, &match?(%NoAgentProfileError{}, &1)) ->
        Refusal.json(conn, 404, "profile_not_found")

      Enum.any?(errors, &match?(%SameKeyError{}, &1)) ->
        Refusal.json(conn, 422, "same_key")

      Enum.any?(errors, &match?(%SendConflictError{}, &1)) ->
        Refusal.json(conn, 422, "idempotency_conflict")

      limit = Enum.find(errors, &match?(%SendLimitError{}, &1)) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(limit.retry_after))
        |> Refusal.json(429, "dm_limit_reached")

      true ->
        Refusal.json(conn, 422, "invalid_dm")
    end
  end

  defp refuse(conn, _fleet_id, _error), do: Refusal.json(conn, 422, "invalid_dm")

  # An agent paired with a person, with no Key of its own, is told what keeps
  # it from acting as theirs.
  defp not_holder(%Agent{pairing: :person_not_here}), do: "person_not_here"
  defp not_holder(%Agent{}), do: "not_your_key"
end
