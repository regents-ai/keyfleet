defmodule KeyfleetWeb.AgentActivityController do
  @moduledoc """
  What has been happening in a fleet, newest first, as its hall shows it, and
  a search of it. Each answers what the Claude connector's `fleets_activity`
  and `fleets_search` answer (`KeyfleetWeb.AgentTools.Fleets.Answer`), cursors
  included.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def index(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:activity, params, conn.assigns.agent_actor, nil))

  def search(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:search, params, conn.assigns.agent_actor, nil))
end
