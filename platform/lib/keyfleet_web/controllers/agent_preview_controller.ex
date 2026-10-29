defmodule KeyfleetWeb.AgentPreviewController do
  @moduledoc """
  What a write would do, before it is sent. It answers what the Claude
  connector's `writes_preview` answers (`KeyfleetWeb.AgentTools.Fleets.Answer`).
  Nothing is written.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def preview(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:preview, params, conn.assigns.agent_actor, nil))
end
