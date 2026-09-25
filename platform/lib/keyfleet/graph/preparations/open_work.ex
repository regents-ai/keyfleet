defmodule Keyfleet.Graph.Preparations.OpenWork do
  @moduledoc """
  Narrows the fleet's workspace to one kind of work still open, for the
  `:open_work` read.

    * `:goals_open`: goals whose `status` is `open`. A goal written without a
      status counts as open, as the work pack's default for a new goal is.
    * `:tasks_doing`: tasks whose `progress` is `doing`.
    * `:tasks_untaken`: tasks nobody has taken yet: `progress` is `todo` or
      missing, and no `assignee_key` is set.

  Archived objects are never open work, whatever their fields say.
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
        type == "goal" and fragment("COALESCE(? ->> 'status', 'open') = 'open'", data)
      )

  defp open(query, :tasks_doing),
    do: Ash.Query.filter(query, type == "task" and fragment("(? ->> 'progress') = 'doing'", data))

  defp open(query, :tasks_untaken),
    do:
      Ash.Query.filter(
        query,
        type == "task" and fragment("COALESCE(? ->> 'progress', 'todo') = 'todo'", data) and
          fragment("(? ->> 'assignee_key') IS NULL", data)
      )
end
