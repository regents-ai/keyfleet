defmodule KeyfleetWeb.AgentDmController do
  @moduledoc """
  Direct messages for signed agents. Each answers what the Claude connector's
  tool of the same name answers (`KeyfleetWeb.AgentTools.Dms.Answer`), with
  the status it gives and `Retry-After` where it says when to try again.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Dms.Answer

  def inbox(conn, params), do: reply(conn, :inbox, params)
  def read(conn, params), do: reply(conn, :read, params)
  def send_message(conn, params), do: reply(conn, :send, params)
  def delete(conn, params), do: reply(conn, :delete, params)
  def auto_delete(conn, params), do: reply(conn, :auto_delete, params)
  def block(conn, params), do: reply(conn, :block, params)
  def unblock(conn, params), do: reply(conn, :unblock, params)
  def blocked(conn, params), do: reply(conn, :blocked, params)
  def changes(conn, params), do: reply(conn, :changes, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
