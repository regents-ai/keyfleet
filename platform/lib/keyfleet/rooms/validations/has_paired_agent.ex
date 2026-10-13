defmodule Keyfleet.Rooms.Validations.HasPairedAgent do
  @moduledoc """
  The signed-in person has an agent paired to their account, to send their
  words to (`Keyfleet.Agents.has_paired_agent?/1`).
  """
  use Ash.Resource.Validation

  alias Keyfleet.Actors.Human
  alias Keyfleet.Rooms.Errors.NoPairedAgentError

  @impl true
  def validate(_changeset, _opts, %{actor: %Human{} = actor}) do
    if Keyfleet.Agents.has_paired_agent?(actor),
      do: :ok,
      else: {:error, NoPairedAgentError.exception([])}
  end

  def validate(_changeset, _opts, _context), do: {:error, NoPairedAgentError.exception([])}
end
