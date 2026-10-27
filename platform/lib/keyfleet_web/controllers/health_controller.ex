defmodule KeyfleetWeb.HealthController do
  @moduledoc "`/healthz`: \"ok\" only while the site's own database answers."
  use KeyfleetWeb, :controller

  def show(conn, _params) do
    {status, body} =
      if database_ready?(), do: {:ok, "ok"}, else: {:service_unavailable, "unavailable"}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp database_ready?, do: Keyfleet.Health.database_ready?()
end
