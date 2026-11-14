defmodule KeyfleetWeb.AgentFundingController do
  @moduledoc """
  Funding a fleet's treasury with NEAR, for signed agents. Each answers what
  the Claude connector's tool of the same name answers
  (`KeyfleetWeb.AgentTools.Fundings.Answer`), with the status it gives.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fundings.Answer

  def price(conn, params), do: reply(conn, :quote, params)
  def start(conn, params), do: reply(conn, :start, params)
  def show(conn, params), do: reply(conn, :show, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
