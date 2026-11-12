defmodule Keyfleet.LeftMessages.Refused do
  @moduledoc """
  Leaving a message refused, named by the refusal `code` every surface answers
  with (`KeyfleetWeb.AgentTools.Account.Answer` holds its words):
  `idempotency_conflict`, or `profile_not_found` for an agent with no profile
  to leave it as.
  """
  use Splode.Error, fields: [:code], class: :invalid

  def message(%{code: code}), do: "Refused: #{code}"
end
