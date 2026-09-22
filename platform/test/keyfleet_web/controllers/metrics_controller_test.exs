defmodule KeyFleetWeb.MetricsControllerTest do
  use KeyFleetWeb.ConnCase, async: false

  test "exposes the bounded Privy browser failure counter", %{conn: conn} do
    :telemetry.execute([:keyfleet, :privy, :browser_failure], %{count: 1}, %{
      reason: "provider_error"
    })

    conn = get(conn, "/metrics")

    assert response(conn, 200) =~
             ~s(keyfleet_privy_browser_failure_total{reason="provider_error"})

    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
