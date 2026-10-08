defmodule Keyfleet.Dms.Preparations.InOrder do
  @moduledoc """
  Reads direct messages oldest first and never more than the reader asked for
  (`limit`), whatever a caller tried to add to the query.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      query
      |> Ash.Query.unset([:sort, :limit, :offset])
      |> Ash.Query.sort(seq: :asc)
      |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
    end)
  end
end
