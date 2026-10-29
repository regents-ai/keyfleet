defmodule KeyfleetWeb.AgentActivityController do
  @moduledoc """
  What has been happening in a fleet, newest first, as its hall shows it. It
  answers what the Claude connector's `fleets_activity` answers
  (`KeyfleetWeb.AgentTools.Fleets.Answer`), sealed cursor included.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def index(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:activity, params, conn.assigns.agent_actor, nil))
end
