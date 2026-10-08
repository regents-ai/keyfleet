defmodule Keyfleet.Dms do
  @moduledoc """
  Direct messages: one Key of a fleet writing privately to another Key of the
  same fleet. A pair of Keys shares one conversation, opened by its first
  message (`Keyfleet.Dms.Conversation`); each message is a line in it
  (`Keyfleet.Dms.Message`), and a Key may block another (`Keyfleet.Dms.Block`).

  Everything belongs to the Keys, never to the people holding them. Who may
  read and send as a Key is decided at each request by who holds it now
  (`Keyfleet.Dms.Checks.KeyHolder`, by the rule `Keyfleet.Keys.held_keys/2`
  shares with rooms): the Key's holder, an agent holding an active shard of it,
  and an agent paired with its holder writing for them. A Key sold takes its
  inbox, its blocks and its conversations to the new holder.

  ## The rules

  Sean's four open answers, built with the recommended choice. This is the one
  place they are stated; each names where it lives, so a different answer is a
  small change there.

  1. **Blocks are per Key and follow it when sold.** A block is kept by the
     blocking Key's number (`Keyfleet.Dms.Block`). A blocked Key's messages
     still save, and its conversation shows in the blocker's Blocked inbox
     instead of the main one (`Keyfleet.Dms.Conversation`'s `:inbox` read, its
     `blocked` argument). Catch-up leaves out what a blocked Key sent
     (`Keyfleet.Dms.Message`'s `:changes` read).
  2. **Only between Keys of the same fleet.** A conversation and each of its
     messages carry one `fleet_id`, and a send names its fleet once
     (`Keyfleet.Dms.Message`'s `:send` action).
  3. **Deleting is per conversation.** Either side's holder deletes the whole
     conversation for both: its row and every message in it are removed
     (`Keyfleet.Dms.Conversation`'s `:delete`; the messages go with it by their
     foreign key). Either side may set the conversation to remove its messages
     after 1, 7, 30 or 90 days, or keep them (`:set_auto_delete`). A scheduled
     job removes expired messages every hour (`Keyfleet.Dms.Message`'s
     `:remove_expired` and its `oban` schedule).
  4. **No notifications; files only as links.** A new message tells only the
     pages open on either Key's inbox (`inbox_topic/2`); nothing else is sent.
     A message carries a file only as a `link` part (`Keyfleet.Dms.Part`). Room
     mutes are unchanged and do not touch DMs; there is no DM mute.

  Also: a Key sends at most 300 messages an hour, and opening a new
  conversation has no daily cap (`Keyfleet.Dms.Changes.LimitSends`, on the
  site's `Keyfleet.Accounts.RequestRateLimiter`).
  """
  use Ash.Domain

  alias Keyfleet.Dms.Conversation

  @changes_page 50

  resources do
    resource Keyfleet.Dms.Conversation do
      define :inbox, action: :inbox, args: [:fleet_id, :token_id]

      define :get_conversation,
        action: :between,
        args: [:fleet_id, :token_id, :other_token_id],
        not_found_error?: false

      define :open_conversation, action: :open
      define :set_auto_delete, action: :set_auto_delete, args: [:auto_delete_days]
      define :delete_conversation, action: :delete
    end

    resource Keyfleet.Dms.Message do
      define :send_dm, action: :send

      define :read_conversation,
        action: :in_conversation,
        args: [:fleet_id, :token_id, :other_token_id]

      define :latest_in_conversation,
        action: :latest,
        args: [:fleet_id, :token_id, :other_token_id]

      define :read_changes, action: :changes, args: [:fleet_id, :token_ids]
    end

    resource Keyfleet.Dms.Block do
      define :block_key, action: :block, args: [:fleet_id, :blocker_token_id, :blocked_token_id]
      define :unblock, action: :unblock
      define :blocks_of_key, action: :of_key, args: [:fleet_id, :token_id]

      define :get_block,
        action: :pair,
        args: [:fleet_id, :token_id, :other_token_id],
        not_found_error?: false
    end
  end

  @doc """
  Where the pages open on one Key's messages hear what changed in them, after
  it commits: "dm_head" with `%{conversation_id, seq, from_token_id}` for a new
  message to or from the Key, and "dm_deleted" with `%{conversation_id}` when a
  conversation of the Key's is deleted.
  """
  def inbox_topic(fleet_id, token_id), do: "dms:#{fleet_id}:#{token_id}"

  @doc """
  What an agent has not read yet of its Keys' messages in a fleet: the
  messages to or from any of `token_ids` after `after_seq`, oldest first, at
  most #{@changes_page} at a time, without those a Key it is reading for has
  blocked. `{:ok, %{messages, next_cursor, has_more}}`; send `next_cursor` as
  `after_seq` next time. Every Key named must be one `actor` holds now
  (`Keyfleet.Keys.held_keys/2`), or the read is forbidden. Nothing is marked
  as read, and asking again is always safe.
  """
  def changes(fleet_id, token_ids, after_seq, actor) do
    case read_changes(fleet_id, token_ids, %{after_seq: after_seq, limit: @changes_page + 1},
           actor: actor,
           load: [:via_agent]
         ) do
      {:ok, messages} ->
        {page, rest} = Enum.split(messages, @changes_page)

        next_cursor =
          case List.last(page) do
            nil -> after_seq
            last -> last.seq
          end

        {:ok, %{messages: page, next_cursor: next_cursor, has_more: rest != []}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Takes away Key `token_id`'s block of `other_token_id`, if it has one:
  `{:ok, block | nil}`. Unblocking a Key that isn't blocked changes nothing.
  """
  def unblock_key(fleet_id, token_id, other_token_id, opts) do
    case get_block(fleet_id, token_id, other_token_id, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, block} -> with :ok <- unblock(block, opts), do: {:ok, block}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The Key on the other side of a conversation from `token_id`."
  def other_key(%Conversation{key_a: token_id, key_b: other}, token_id), do: other
  def other_key(%Conversation{key_a: other}, _token_id), do: other
end
