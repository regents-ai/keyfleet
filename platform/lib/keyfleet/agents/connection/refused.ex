defmodule Keyfleet.Agents.Connection.Refused do
  @moduledoc """
  A connected app's identity request was refused. `error` is the
  `{"code", "message", "hint"}` this site answered the signed request with, the
  one `RegentMCPAgents` made before signing anything, such as
  `pairing_code_unknown`, or, when the sign-in service or this site said to
  wait, `too_many_requests` in `RegentMCPAgents.Tools.wait/1`'s words;
  `retry_after` is the seconds the answer's `Retry-After` named. With no
  `error`, no answer came that can be passed on, and the words are
  `RegentMCPAgents.Tools.refusal/0`'s.
  """
  use Splode.Error, fields: [:error, :retry_after], class: :forbidden

  def message(%{error: %{"message" => message}}), do: message
  def message(_error), do: "The identity request could not be completed."
end
