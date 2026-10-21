defmodule Keyfleet.Graph.Preparations.OpenWork do
  @moduledoc """
  Narrows the fleet's workspace to one kind of work still open, for the
  `:open_work` read. This is the one definition of open work: the directory
  and `Keyfleet.Graph.trying_now/1` both read it.

    * `:goals_open`: goals whose `status` is `open`, not `achieved` or
      `dropped`. A starting goal, one of the ideas every workspace begins
      with, is open work only once someone has joined it.
    * `:tasks_taken`: unfinished tasks a key has taken: an `assignee_key` is
      set and `progress` is `todo`, `doing` or `blocked`, so a task given to a
      key counts before the key starts it.
    * `:tasks_untaken`: unfinished tasks nobody has taken: no `assignee_key`.

  Every unfinished task is either taken or not taken yet. Archived objects
  are never open work, whatever their fields say. The work pack gives every
  goal a `status` and every task a `progress`.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  # A kind that isn't one of these has already been refused as an argument;
  # the read answers that error.
  @impl true
  def prepare(%Ash.Query{valid?: false} = query, _opts, _context), do: query

  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(fragment("(? ->> 'archived') IS DISTINCT FROM 'true'", sys))
    |> open(Ash.Query.get_argument(query, :kind))
  end

  defp open(query, :goals_open),
    do:
      Ash.Query.filter(
        query,
        type == "goal" and fragment("(? ->> 'status') = 'open'", data) and
          fragment(
            "(? ->> 'starting' IS NULL OR jsonb_array_length(? -> 'joined') > 0)",
            sys,
            sys
          )
      )

  defp open(query, :tasks_taken),
    do:
      query
      |> unfinished_tasks()
      |> Ash.Query.filter(fragment("(? ->> 'assignee_key') IS NOT NULL", data))

  defp open(query, :tasks_untaken),
    do:
      query
      |> unfinished_tasks()
      |> Ash.Query.filter(fragment("(? ->> 'assignee_key') IS NULL", data))

  defp unfinished_tasks(query),
    do:
      Ash.Query.filter(
        query,
        type == "task" and fragment("(? ->> 'progress') IN ('todo', 'doing', 'blocked')", data)
      )
end
