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

  test "exposes the keeper's transactions, pauses, balance and spending", %{conn: conn} do
    :telemetry.execute([:keyfleet, :keeper, :tx], %{count: 1}, %{
      function: :request_reveal,
      outcome: :reverted
    })

    :telemetry.execute([:keyfleet, :keeper, :paused], %{count: 1}, %{
      job: :income,
      reason: :spend_ceiling
    })

    :telemetry.execute([:keyfleet, :keeper], %{wallet_balance_wei: 42, spent_24h_wei: 7}, %{})

    body = conn |> get("/metrics") |> response(200)

    assert body =~ ~s(keyfleet_keeper_tx_total{function="request_reveal",outcome="reverted"})
    assert body =~ ~s(keyfleet_keeper_paused_total{job="income",reason="spend_ceiling"})
    assert body =~ ~r/^keyfleet_keeper_wallet_balance_wei 42$/m
    assert body =~ ~r/^keyfleet_keeper_spent_24h_wei 7$/m
  end
end
