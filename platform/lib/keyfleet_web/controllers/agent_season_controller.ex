defmodule KeyfleetWeb.AgentSeasonController do
  @moduledoc """
  A fleet's seasons for signed agents. Each answers what the Claude
  connector's tool of the same name answers
  (`KeyfleetWeb.AgentTools.Seasons.Answer`), with the status it gives.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Seasons.Answer

  def show(conn, params), do: reply(conn, :show, params)
  def pick(conn, params), do: reply(conn, :pick, params)
  def list(conn, params), do: reply(conn, :list, params)
  def coins(conn, params), do: reply(conn, :coins, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
