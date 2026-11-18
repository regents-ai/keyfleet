defmodule Keyfleet.Seasons.Checks.Member do
  @moduledoc """
  Whether the actor is a member of the fleet a seasons action names
  (`Keyfleet.Access.member?/2`): anyone holding one of its Keys, or an active
  shard of one, or an agent paired with a person who holds one. Read from the
  Keys every time, so a Key changing hands moves it at once; while the fleet's
  Key ownership is not fresh, nobody is a member.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a member of the fleet"

  @impl true
  def match?(actor, %{subject: subject}, _opts),
    do: Keyfleet.Access.member?(actor, Ash.Subject.get_argument_or_attribute(subject, :fleet_id))
end
