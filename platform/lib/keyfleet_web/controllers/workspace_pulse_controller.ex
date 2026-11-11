defmodule KeyfleetWeb.WorkspacePulseController do
  @moduledoc """
  Public activity summaries; never inherits browser or agent membership. It
  answers what the Claude connector's `workspace_pulse` answers
  (`KeyfleetWeb.AgentTools.Public.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Public.Answer

  def show(conn, params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> AgentReply.answer(Answer.answer(:pulse, params, nil, nil))
  end
end
