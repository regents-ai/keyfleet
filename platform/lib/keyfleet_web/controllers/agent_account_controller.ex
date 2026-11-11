defmodule KeyfleetWeb.AgentAccountController do
  @moduledoc """
  Shared account reads for the current, verified agent pairing. Each answers
  what the Claude connector's tool of the same name answers
  (`KeyfleetWeb.AgentTools.Account.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Account.Answer

  def points(conn, params), do: reply(conn, :points, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
