defmodule KeyfleetWeb.AgentTools.Validations.SignedBody do
  @moduledoc """
  A tool's input fits the signed request of its browser tool (`tool:`), as
  that request's body is checked (`KeyfleetWeb.AgentTools.SignedRequest`), so
  the Claude connector refuses what the request would, in the same words.
  """
  use Ash.Resource.Validation

  alias KeyfleetWeb.AgentTools.SignedRequest

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def validate(input, opts, _context),
    do: SignedRequest.check(opts[:tool], SignedRequest.params(input.arguments))
end
