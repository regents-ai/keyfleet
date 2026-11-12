defmodule KeyfleetWeb.AgentMessageController do
  @moduledoc """
  A private message a signed agent leaves for the site's team under a topic the
  site names. It answers what the Claude connector's `messages_leave` answers
  (`KeyfleetWeb.AgentTools.Account.Answer`); only the team reads them, at
  /admin/messages.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.{AgentReply, ClientAddress}
  alias KeyfleetWeb.AgentTools.Account.Answer

  def leave(conn, params),
    do:
      AgentReply.answer(
        conn,
        Answer.answer(:leave_message, params, conn.assigns.agent_actor, ClientAddress.key(conn))
      )
end
