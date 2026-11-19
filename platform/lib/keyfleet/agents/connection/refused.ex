defmodule Keyfleet.Agents.Connection.Refused do
  @moduledoc """
  A connected app's identity request was refused. `error` is the
  `{"code", "message", "hint"}` this site answered the signed request with, or
  the one `RegentMCPAgents` made before signing anything, such as
  `pairing_code_unknown`; `retry_after` is the site's `Retry-After`. With no
  `error`, no refusal of this site's own came back, as when the sign-in service
  that holds the app's signing key refused the request or did not answer, and
  the words are `RegentMCPAgents.Tools.refusal/0`'s.
  """
  use Splode.Error, fields: [:error, :retry_after], class: :forbidden

  def message(%{error: %{"message" => message}}), do: message
  def message(_error), do: "The identity request could not be completed."
end
