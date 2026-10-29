defmodule Keyfleet.Notebooks.Changes.ForgetScratchpads do
  @moduledoc """
  A fleet's `scratchpad` leaving takes with it, in the same transaction, the
  record of which Key's notebook each one in it was (`Keyfleet.Notebooks.Setting`),
  so no Key keeps a scratchpad the fleet no longer has.
  """
  use Ash.Resource.Change

  alias Keyfleet.Notebooks.Setting

  @system %Keyfleet.Actors.System{}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, project ->
      if project.name == "scratchpad" do
        Setting
        |> Ash.Query.for_read(:scratchpads, %{fleet_id: project.fleet_id}, actor: @system)
        |> Ash.bulk_destroy!(:forget, %{},
          actor: @system,
          strategy: [:atomic],
          return_errors?: true
        )
      end

      {:ok, project}
    end)
  end
end
