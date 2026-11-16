defmodule Keyfleet.FeedHelpers do
  @moduledoc """
  The missed events' read answers only events five seconds old by the
  database's clock (`Keyfleet.Feed.missed/3`). A test makes its events older
  instead of waiting: `age!/0` moves every post and direct message so far ten
  seconds back, and `earlier/1` moves a cursor held from before by as much,
  so the test reads as if it had run that much sooner.
  """

  alias Keyfleet.Feed
  alias Keyfleet.Repo

  @aged_seconds 10

  @doc "Moves every post and direct message so far `@aged_seconds` into the past."
  def age! do
    # Posts are never edited, so their guard is off for the move, inside the
    # test's own transaction.
    Repo.query!("ALTER TABLE keyfleet_app.messages DISABLE TRIGGER immutable_messages")

    for table <- ["messages", "dm_messages"] do
      Repo.query!(
        "UPDATE keyfleet_app.#{table} SET inserted_at = inserted_at - make_interval(secs => #{@aged_seconds})"
      )
    end

    Repo.query!("ALTER TABLE keyfleet_app.messages ENABLE TRIGGER immutable_messages")
    :ok
  end

  @doc "A cursor held from before `age!/0`, moved back as far."
  def earlier(cursor),
    do: Integer.to_string(String.to_integer(cursor) - @aged_seconds * 1_000_000)

  @doc "The id `message` has after `age!/0`."
  def aged_id(message),
    do: message.inserted_at |> DateTime.add(-@aged_seconds, :second) |> Feed.id()
end
