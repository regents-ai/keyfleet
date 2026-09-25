defmodule KeyfleetWeb.MetricsControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  test "exposes the bounded Privy browser failure counter", %{conn: conn} do
    :telemetry.execute([:keyfleet, :privy, :browser_failure], %{count: 1}, %{
      reason: "provider_error"
    })

    conn = get(conn, "/metrics")

    assert response(conn, 200) =~
             ~s(keyfleet_privy_browser_failure_total{reason="provider_error"})

    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "exposes the keeper's transactions, pauses, balance, spending and reveals", %{conn: conn} do
    :telemetry.execute([:keyfleet, :keeper, :tx], %{count: 1}, %{
      function: :request_reveal,
      outcome: :reverted
    })

    :telemetry.execute([:keyfleet, :keeper, :paused], %{count: 1}, %{
      job: :income,
      reason: :spend_ceiling
    })

    :telemetry.execute([:keyfleet, :keeper], %{wallet_balance_wei: 42, spent_24h_wei: 7}, %{})

    :telemetry.execute([:keyfleet, :keeper, :vrf], %{native_balance_wei: 30}, %{
      fleet: "fleet_tech_classic"
    })

    :telemetry.execute([:keyfleet, :keeper, :reveals], %{waiting: 3}, %{
      fleet: "fleet_tech_classic"
    })

    body = conn |> get("/metrics") |> response(200)

    assert body =~ ~s(keyfleet_keeper_tx_total{function="request_reveal",outcome="reverted"})
    assert body =~ ~s(keyfleet_keeper_paused_total{job="income",reason="spend_ceiling"})
    assert body =~ ~r/^keyfleet_keeper_wallet_balance_wei 42$/m
    assert body =~ ~r/^keyfleet_keeper_spent_24h_wei 7$/m

    assert body =~
             ~r/^keyfleet_keeper_vrf_native_balance_wei\{fleet="fleet_tech_classic"\} 30$/m

    assert body =~ ~r/^keyfleet_keeper_reveals_waiting\{fleet="fleet_tech_classic"\} 3$/m
  end
end
