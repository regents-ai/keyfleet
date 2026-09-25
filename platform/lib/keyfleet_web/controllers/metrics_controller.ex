defmodule KeyfleetWeb.MetricsController do
  use KeyfleetWeb, :controller

  def show(conn, _params) do
    body =
      TelemetryMetricsPrometheus.Core.scrape(KeyfleetWeb.Telemetry.prometheus_reporter())

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:ok, body)
  end
end
