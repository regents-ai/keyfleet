defmodule Keyfleet.Graph.Checks.KeyReader do
  @moduledoc """
  Who may read a fleet's workspace: the person or agent whose wallet owns one
  of the fleet's keys today, or an agent holding an active shard of one, while
  the fleet's key ownership is fresh. A read names no key; standing is read
  every time, as `Keyfleet.Graph.Checks.KeyActor.member/3` reads it, so a key
  changing hands moves the right to read with it, and an ownership that is
  stale or being read again grants nothing.

  The summary a fleet shows anyone, its open goals, how much work is open and
  its latest activity, is read by actions this check does not guard.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Graph.Checks.KeyActor

  @impl true
  def describe(_opts),
    do:
      "actor owns one of the fleet's keys today or holds a shard of one, " <>
        "while the fleet's ownership is fresh"

  @impl true
  def match?(actor, %{subject: subject}, _opts) do
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]
    KeyActor.member(actor, fleet_id(subject), within) == {:ok, true}
  end

  defp fleet_id(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :fleet_id)
  defp fleet_id(%Ash.ActionInput{arguments: arguments}), do: arguments.fleet_id
end
