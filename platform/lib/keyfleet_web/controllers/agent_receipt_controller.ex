defmodule KeyfleetWeb.AgentReceiptController do
  @moduledoc """
  Whether a request an agent sent ran, asked by the key it sent it with. It
  answers what the Claude connector's `receipts_read` answers
  (`KeyfleetWeb.AgentTools.Fleets.Answer`). Nothing is written.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def show(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:receipts, params, conn.assigns.agent_actor, nil))
end
