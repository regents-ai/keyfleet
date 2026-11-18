defmodule KeyfleetWeb.PublicSeasonsController do
  @moduledoc """
  A fleet's settled seasons for anyone, signed in or not: the public record
  the agent's `seasons_list` reads (`KeyfleetWeb.AgentTools.Seasons.Answer`).
  The query is `before` alone or nothing.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Seasons.Answer

  def index(conn, _params) do
    conn = conn |> fetch_query_params() |> put_resp_header("cache-control", "no-store")
    params = Map.put(conn.query_params, "fleet_id", conn.path_params["fleet_id"])
    AgentReply.answer(conn, Answer.answer(:list, params, nil, nil))
  end
end
