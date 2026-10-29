defmodule KeyfleetWeb.AgentTools.Run do
  @moduledoc """
  Runs an agent tool's action as the calling agent, as the signed request of
  its browser tool (`tool:`) would run: the action's input becomes that
  request's JSON, with any `fixed:` fields the browser tool always sends; its
  body is checked as the request's is; and the resource's `Answer` module
  (`KeyfleetWeb.AgentTools.Rooms.Answer` for `KeyfleetWeb.AgentTools.Rooms`)
  answers the action's name as it answers the request. Waits for news are
  counted under the `waiter` its caller puts in the action's context.
  """
  use Ash.Resource.Actions.Implementation

  alias KeyfleetWeb.AgentTools.SignedRequest

  @impl true
  def run(input, opts, context) do
    params = SignedRequest.params(input.arguments, Keyword.get(opts, :fixed, %{}))

    with :ok <- SignedRequest.check(opts[:tool], params) do
      answer = Module.concat(input.resource, "Answer")
      waiter = Map.fetch!(context.source_context, :waiter)

      SignedRequest.result(answer.answer(input.action.name, params, context.actor, waiter))
    end
  end
end
