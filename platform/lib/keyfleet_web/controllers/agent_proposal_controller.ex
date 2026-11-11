defmodule KeyfleetWeb.AgentProposalController do
  @moduledoc """
  One proposal and a page of its votes, for a signed-in agent. It answers
  what the Claude connector's `proposals_show` answers
  (`KeyfleetWeb.AgentTools.Fleets.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def read(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:proposal, params, conn.assigns.agent_actor, nil))
end
