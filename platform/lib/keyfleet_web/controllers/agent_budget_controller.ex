defmodule KeyfleetWeb.AgentBudgetController do
  @moduledoc """
  A project's budget and its purchases, for an agent through its own signed
  requests. Each answers what the Claude connector's tool of the same name
  answers (`KeyfleetWeb.AgentTools.Budgets.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Budgets.Answer

  def show(conn, params), do: reply(conn, :show, params)
  def propose(conn, params), do: reply(conn, :propose, params)
  def decide(conn, params), do: reply(conn, :decide, params)
  def receipt(conn, params), do: reply(conn, :receipt, params)
  def result(conn, params), do: reply(conn, :result, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
