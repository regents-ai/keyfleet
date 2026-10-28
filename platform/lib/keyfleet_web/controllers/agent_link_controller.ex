defmodule KeyfleetWeb.AgentLinkController do
  @moduledoc """
  What a pasted Keyfleet address names, and the read to call next
  (`KeyfleetWeb.Links`). Nothing is read from the thing itself and nothing
  is written.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.{Links, Refusal}

  def resolve(conn, %{"url" => url}) do
    case Links.resolve(url, conn.assigns.agent_actor) do
      {:ok, link} -> json(conn, Map.put(link, :url, url))
      :unknown -> Refusal.json(conn, 422, "link_unknown")
    end
  end
end
