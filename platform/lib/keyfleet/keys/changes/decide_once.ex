defmodule Keyfleet.Keys.Changes.DecideOnce do
  @moduledoc """
  Makes the standing the caller acted on part of the row's own update condition.

  A page that has not caught up still shows a request as open, so the decision
  it sends has to find the key exactly as it was read; anything decided in the
  meantime stands, and the caller is told its page is out of date.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.filter(changeset, Ash.Expr.expr(status == ^opts[:from]))
  end
end
