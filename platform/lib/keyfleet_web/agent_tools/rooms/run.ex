defmodule KeyfleetWeb.AgentTools.Rooms.Run do
  @moduledoc """
  Runs one of `KeyfleetWeb.AgentTools.Rooms`' actions as the calling agent:
  its input as the signed request's JSON, answered as that request is
  (`KeyfleetWeb.AgentTools.Rooms.Answer`). A sync's waits are counted under
  the `waiter` its caller puts in the action's context.
  """
  use Ash.Resource.Actions.Implementation

  alias KeyfleetWeb.AgentTools.Rooms.Answer
  alias KeyfleetWeb.AgentTools.SignedRequest

  @impl true
  def run(input, opts, context) do
    opts[:op]
    |> Answer.answer(
      SignedRequest.params(input.arguments),
      context.actor,
      Map.fetch!(context.source_context, :waiter)
    )
    |> SignedRequest.result()
  end
end
