defmodule Keyfleet.Keys.DeckEnding do
  @moduledoc """
  A fleet is within 100 Keys of the end of its deck while later Keys draw
  their cards with Chainlink randomness (`Keyfleet.Keys.DeckEndCheck`): the
  randomness subscription has to be ready before the first Key past the deck
  sells, or that Key waits in Revealing. One error at /admin/errors
  (`Keyfleet.Alert`).
  """
  defexception [:message]

  @doc """
  Saves it, with `message` saying which fleets and what to do. The caller's
  line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end
