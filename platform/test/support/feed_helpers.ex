defmodule Keyfleet.FeedHelpers do
  @moduledoc """
  The missed events' read answers only events `Keyfleet.Feed.settling_seconds/0`
  old by the database's clock. A test makes its events older instead of
  waiting: `age!/0` moves every post and direct message so far twice that far
  back, and `earlier/1` moves a cursor held from before by as much, so the
  test reads as if it had run that much sooner. `database_clock/0` is the clock
  every event's id is read from.
  """

  alias Keyfleet.Feed
  alias Keyfleet.Repo

  @doc "The database's clock now, which every event's id and the settled moment are read from."
  def database_clock do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  @doc "Moves every post and direct message so far twice the settling time into the past."
  def age! do
    # Posts are never edited, so their guard is off for the move, inside the
    # test's own transaction.
    Repo.query!("ALTER TABLE keyfleet_app.messages DISABLE TRIGGER immutable_messages")

    for table <- ["messages", "dm_messages"] do
      Repo.query!(
        "UPDATE keyfleet_app.#{table} SET inserted_at = inserted_at - make_interval(secs => $1)",
        [aged_seconds()]
      )
    end

    Repo.query!("ALTER TABLE keyfleet_app.messages ENABLE TRIGGER immutable_messages")
    :ok
  end

  @doc "A cursor held from before `age!/0`, moved back as far."
  def earlier(cursor),
    do: Integer.to_string(String.to_integer(cursor) - aged_seconds() * 1_000_000)

  @doc "The id `message` has after `age!/0`."
  def aged_id(message),
    do: message.inserted_at |> DateTime.add(-aged_seconds(), :second) |> Feed.id()

  # More than the settling time, so an event aged once is old enough for
  # every read after it.
  defp aged_seconds, do: 2 * Feed.settling_seconds()
end
