defmodule Keyfleet.Rooms.Changes.LimitPosts do
  @moduledoc """
  Holds each key to 300 posts an hour that people write themselves, and to
  300 an hour that agents write, counted apart from the posts stored in the
  last hour (`Keyfleet.Rooms.Message`'s `:page_posts_last_hour` and
  `:agent_posts_last_hour`), across the fleet's rooms and keys' threads.

  People post from the page and its tools, which the API's per-address limit
  doesn't reach. Agents post through the API, but an agent changing its
  address would start that limit again, so the posts written as a key are
  counted too: an agent's own and the ones it writes for its person alike.

  A refused post stores nothing, so it never counts; a repeat of a post
  already made is handed back, never refused. The count is the database's, so
  every machine sees the same one and a deploy keeps it. It runs after
  `Keyfleet.Rooms.Changes.PostMessage` has settled the key the post is
  written as, and holds that key's posts for this one alone until it
  commits, so two posts as one key at the same moment, in two rooms or
  threads, are counted one after the other.
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
    Ash.Changeset.before_action(changeset, fn
      %{valid?: true} = changeset -> limit(changeset, actor)
      changeset -> changeset
    end)
  end

  defp limit(changeset, actor) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :as_key)

    Keyfleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["posts_as_key", fleet_id, token_id])
    ])

    # The 300th newest post of the hour: while there is one, the key is at
    # its limit until that post is an hour old.
    case Message
         |> Ash.Query.for_read(
           counted(changeset),
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

  # A person's own post, or one an agent writes, for itself or for its person.
  defp counted(changeset) do
    if Ash.Changeset.get_attribute(changeset, :author_kind) == :human and
         is_nil(Ash.Changeset.get_attribute(changeset, :via_agent_profile_id)),
       do: :page_posts_last_hour,
       else: :agent_posts_last_hour
  end

  # Looked for as the one posting, who may read their own posts on every
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
