defmodule KeyfleetWeb.AgentAccountController do
  @moduledoc """
  The verified agent pairing's Credits history, answered as the Claude
  connector's `credits_history` tool answers it
  (`KeyfleetWeb.AgentTools.Account.Answer`) from the request's JSON body alone.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Account.Answer

  def credits_history(conn, _params) do
    AgentReply.answer(
      conn,
      Answer.answer(:credits_history, conn.body_params, conn.assigns.agent_actor, nil)
    )
  end
end
