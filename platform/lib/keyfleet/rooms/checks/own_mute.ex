defmodule Keyfleet.Rooms.Checks.OwnMute do
  @moduledoc "The actor's own mutes, and nobody else's."
  use Ash.Policy.FilterCheck

  alias Keyfleet.Rooms.Muter

  @impl true
  def describe(_opts), do: "the mute is the actor's own"

  @impl true
  def filter(actor, _authorizer, _opts), do: expr(muter == ^Muter.of(actor))
end
