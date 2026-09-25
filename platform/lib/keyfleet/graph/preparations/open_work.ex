defmodule Keyfleet.Graph.Preparations.OpenWork do
  @moduledoc """
  Narrows the fleet's workspace to one kind of work still open, for the
  `:open_work` read. This is the one definition of open work: the directory
  and `Keyfleet.Graph.trying_now/1` both read it.

    * `:goals_open`: goals whose `status` is `open`, not `achieved` or
      `dropped`.
    * `:tasks_doing`: tasks a key has taken and is working on: `progress` is
      `doing` and an `assignee_key` is set. A task marked doing that no key
      has taken has nobody on it, so it isn't anyone's work in progress.
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
    do: Ash.Query.filter(query, type == "goal" and fragment("(? ->> 'status') = 'open'", data))

  defp open(query, :tasks_doing),
    do:
      Ash.Query.filter(
        query,
        type == "task" and fragment("(? ->> 'progress') = 'doing'", data) and
          fragment("(? ->> 'assignee_key') IS NOT NULL", data)
      )

  defp open(query, :tasks_untaken),
    do:
      Ash.Query.filter(
        query,
        type == "task" and fragment("(? ->> 'progress') = 'todo'", data) and
          fragment("(? ->> 'assignee_key') IS NULL", data)
      )
end
