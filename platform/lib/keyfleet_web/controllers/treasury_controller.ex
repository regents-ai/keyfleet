defmodule KeyfleetWeb.TreasuryController do
  @moduledoc """
  Public treasury figures shared with the fleet page; no wallet authority. It
  answers what the Claude connector's `treasury_show` answers
  (`KeyfleetWeb.AgentTools.Public.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Public.Answer

  def show(conn, params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> AgentReply.answer(Answer.answer(:treasury, params, nil, nil))
  end
end
