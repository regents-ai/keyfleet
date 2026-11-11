defmodule KeyfleetWeb.AgentShardController do
  @moduledoc """
  The signed-in agent's active shards, one per key, each with the
  transaction that ends it. It answers what the Claude connector's
  `shards_list` answers (`KeyfleetWeb.AgentTools.Keys.Answer`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Keys.Answer

  def index(conn, params),
    do: AgentReply.answer(conn, Answer.answer(:shards, params, conn.assigns.agent_actor, nil))
end
