defmodule KeyFleet.Checks.AgentActor do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor is a verified KeyFleet Base wallet principal"

  @impl true
  def match?(actor, _context, _opts), do: KeyFleet.Actors.Agent.valid?(actor)
end
