defmodule KeyfleetWeb.AgentLinkController do
  @moduledoc """
  What a pasted Keyfleet address names, and the read to call next. It
  answers what the Claude connector's `links_resolve` answers
  (`KeyfleetWeb.AgentTools.Fleets.Answer`). Nothing is written.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def resolve(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:link, params, conn.assigns.agent_actor, nil))
end
