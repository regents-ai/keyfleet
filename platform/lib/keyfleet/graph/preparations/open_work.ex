defmodule Keyfleet.Graph.Preparations.OpenWork do
  @moduledoc """
  Narrows the fleet's workspace to one kind of work still open, for the
  `:open_work` read. This is the one definition of open work: the directory
  and `Keyfleet.Graph.trying_now/1` both read it.

    * `:goals_open`: goals whose `status` is `open`, not `achieved` or
      `dropped`. A starting goal, one of the ideas every workspace begins
      with, is open work only once someone has joined it.
    * `:tasks_doing`: tasks whose `progress` is `doing`, whether or not a
      key has taken them.
    * `:tasks_taken`: the tasks of `:tasks_doing` that a key has taken: an
      `assignee_key` is set.
    * `:tasks_untaken`: tasks nobody has taken yet: `progress` is `todo` and
      no `assignee_key` is set.

  Archived objects are never open work, whatever their fields say. The work
  pack gives every goal a `status` and every task a `progress`.
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

  defp open(query, :tasks_doing),
    do: Ash.Query.filter(query, type == "task" and fragment("(? ->> 'progress') = 'doing'", data))

  defp open(query, :tasks_taken),
    do:
      query
      |> open(:tasks_doing)
      |> Ash.Query.filter(fragment("(? ->> 'assignee_key') IS NOT NULL", data))

  defp open(query, :tasks_untaken),
    do:
      Ash.Query.filter(
        query,
        type == "task" and fragment("(? ->> 'progress') = 'todo'", data) and
          fragment("(? ->> 'assignee_key') IS NULL", data)
      )
end
