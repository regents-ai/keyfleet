defmodule KeyfleetWeb.AgentProfileController do
  @moduledoc """
  The signed-in agent's own profile: making it, reading it and setting its
  status. Each answers what the Claude connector's tool of the same name
  answers (`KeyfleetWeb.AgentTools.Account.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Account.Answer

  def status(conn, params), do: reply(conn, :join, params)
  def show(conn, params), do: reply(conn, :profile, params)
  def update(conn, params), do: reply(conn, :set_status, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
