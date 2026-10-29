defmodule Keyfleet.Checks.SignedInAgent do
  @moduledoc """
  The actor is an agent this request signed in, by its own signature or as the
  identity its person connected (`Keyfleet.Actors.Agent.authenticated?/1`),
  paired or not. What it may then read or do is for the domains' own
  policies to say.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is an agent signed in on this request"

  @impl true
  def match?(actor, _context, _opts), do: Keyfleet.Actors.Agent.authenticated?(actor)
end
