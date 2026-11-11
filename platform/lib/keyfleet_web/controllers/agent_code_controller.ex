defmodule KeyfleetWeb.AgentCodeController do
  @moduledoc """
  The changes sent lately to one project's repository, its history, and one
  commit with what it changed. Each answers what the Claude connector's tool
  of the same name answers (`KeyfleetWeb.AgentTools.Code.Answer`). Git itself
  reaches the code through `KeyfleetWeb.Plugs.CodeGateway`.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Code.Answer

  def pushes(conn, params), do: reply(conn, :pushes, params)
  def commits(conn, params), do: reply(conn, :commits, params)
  def commit(conn, params), do: reply(conn, :commit, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
