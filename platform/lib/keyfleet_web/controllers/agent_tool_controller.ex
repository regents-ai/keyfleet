defmodule KeyfleetWeb.AgentToolController do
  @moduledoc """
  An agent's signed request answered as the Claude connector's tool of the
  same name answers it. Each route's scope names the tool's `Answer` module
  in `conn.private.answer` and the route's action is the tool's operation, so
  `/api/v1/agent/fleets/:fleet_id/rooms` is `KeyfleetWeb.AgentTools.Rooms.Answer`'s
  `:list`. The reply carries the answer's status, its JSON body and, when it
  says when to try again, `Retry-After`. A sync's waits are counted by the
  address the request came from (`KeyfleetWeb.ClientAddress.key/1`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.{AgentReply, ClientAddress}

  def action(%Plug.Conn{private: %{answer: answer}} = conn, _opts) do
    reply =
      answer.answer(
        action_name(conn),
        conn.params,
        conn.assigns.agent_actor,
        ClientAddress.key(conn)
      )

    AgentReply.answer(conn, reply)
  end
end
