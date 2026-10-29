defmodule KeyfleetWeb.AgentMuteController do
  @moduledoc """
  The signed-in agent's own mutes in a fleet: the keys whose posts it has
  chosen not to see. Each answers what the Claude connector's tool of the
  same name answers (`KeyfleetWeb.AgentTools.Keys.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Keys.Answer

  def index(conn, params), do: reply(conn, :mutes, params)
  def create(conn, params), do: reply(conn, :mute, params)
  def delete(conn, params), do: reply(conn, :unmute, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
