defmodule Keyfleet.Notebooks.Changes.QueueRoster do
  @moduledoc """
  A project's space recorded queues the fleet's roster run
  (`Keyfleet.Notebooks.Roster`) in the same transaction, so every member is
  made an editor of the new space.
  """
  use Ash.Resource.Change

  alias Keyfleet.Notebooks.Roster

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, project ->
      Oban.insert!(Roster.new(%{fleet_id: project.fleet_id}))
      {:ok, project}
    end)
  end
end
