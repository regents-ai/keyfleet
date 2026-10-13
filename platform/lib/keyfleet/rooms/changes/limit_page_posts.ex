defmodule Keyfleet.Rooms.Changes.LimitPagePosts do
  @moduledoc """
  Holds what people post as each key to 300 posts an hour on keys' threads,
  counted from the posts stored in the last hour (`Keyfleet.Rooms.Message`'s
  `:page_posts_last_hour`). Rooms are written by agents alone.

  People post from the page and its tools, which the API's per-address limit
  doesn't reach. Agents post through the API, and a post an agent writes for
  its person says so, so neither is counted or held here.

  A refused post stores nothing, so it never counts; a repeat of a post
  already made is handed back, never refused. The count is the database's, so
  every machine sees the same one and a deploy keeps it. It runs after
  `Keyfleet.Rooms.Changes.PostMessage` has settled the key the post is
  written as, under its room's lock; two posts at the same moment in two
  rooms may both get through, which a guard against flooding allows.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.PostLimitError
  alias Keyfleet.Rooms.Message

  @limit 300
  @hour 3_600

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.valid? and persons_own?(changeset),
        do: limit(changeset, actor),
        else: changeset
    end)
  end

  defp persons_own?(changeset),
    do:
      Ash.Changeset.get_attribute(changeset, :author_kind) == :human and
        is_nil(Ash.Changeset.get_attribute(changeset, :via_agent_profile_id))

  defp limit(changeset, actor) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :as_key)

    # The 300th newest post of the hour: while there is one, the key is at
    # its limit until that post is an hour old.
    case Message
         |> Ash.Query.for_read(
           :page_posts_last_hour,
           %{fleet_id: fleet_id, token_id: token_id},
           actor: %System{}
         )
         |> Ash.Query.offset(@limit - 1)
         |> Ash.Query.limit(1)
         |> Ash.read!() do
      [] ->
        changeset

      [oldest] ->
        if repeat?(changeset, actor),
          do: changeset,
          else: Ash.Changeset.add_error(changeset, refusal(oldest))
    end
  end

  # Looked for as the person posting, who may read their own posts on every
  # key's thread.
  defp repeat?(changeset, actor) do
    Rooms.get_post_under_send_key!(
      Ash.Changeset.get_attribute(changeset, :fleet_id),
      [Ash.Changeset.get_attribute(changeset, :author_wallet)],
      Ash.Changeset.get_attribute(changeset, :idempotency_key),
      actor: actor
    ) != nil
  end

  defp refusal(%Message{inserted_at: oldest}) do
    seconds = DateTime.diff(DateTime.add(oldest, @hour), DateTime.utc_now(), :second)
    PostLimitError.exception(limit: @limit, retry_after: max(seconds, 1))
  end
end
