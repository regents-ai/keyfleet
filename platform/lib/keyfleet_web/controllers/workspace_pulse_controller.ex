defmodule KeyfleetWeb.WorkspacePulseController do
  @moduledoc "Public activity summaries; never inherits browser or agent membership."
  use KeyfleetWeb, :controller

  def show(conn, %{"fleet_id" => fleet_id}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Keyfleet.WorkspacePulse.read(fleet_id) do
      {:ok, pulse} -> json(conn, pulse)
      :unknown -> KeyfleetWeb.Refusal.json(conn, 404, "fleet_unknown")
      {:error, _error} -> KeyfleetWeb.Refusal.json(conn, 503, "graph_unavailable")
    end
  end
end
