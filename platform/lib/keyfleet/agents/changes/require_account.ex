defmodule Keyfleet.Agents.Changes.RequireAccount do
  @moduledoc """
  Rechecks, inside the mutation's transaction, that the agent still acts for its
  account: an agent that owns its account still owns the same one
  (`Keyfleet.Actors.Agent.valid?/1`), and any other agent still holds its pairing
  (`RegentAgents.RequirePairing`).
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.Agent

  @impl true
  def change(changeset, _opts, %{actor: %Agent{owner?: true} = owner}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if Agent.valid?(owner),
        do: changeset,
        else: Ash.Changeset.add_error(changeset, "active account required")
    end)
  end

  def change(changeset, _opts, context),
    do: RegentAgents.RequirePairing.change(changeset, [repo: Keyfleet.Repo], context)
end
