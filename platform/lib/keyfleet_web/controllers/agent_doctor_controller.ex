defmodule KeyfleetWeb.AgentDoctorController do
  @moduledoc """
  An agent's standing in one fleet, in one read. It answers what the Claude
  connector's `fleets_doctor` answers (`KeyfleetWeb.AgentTools.Fleets.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  def show(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:doctor, params, conn.assigns.agent_actor, nil))
end
