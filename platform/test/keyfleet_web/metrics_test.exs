defmodule KeyfleetWeb.MetricsTest do
  use KeyfleetWeb.ConnCase, async: false

  # The listener as the site starts it, on loopback at a port the system picks.
  setup do
    {:ok, {ip, port}} =
      KeyfleetWeb.Metrics |> start_supervised!() |> ThousandIsland.listener_info()

    %{ip: ip, url: "http://127.0.0.1:#{port}"}
  end

  test "the private listener answers on loopback only", %{ip: ip, url: url} do
    assert ip == {127, 0, 0, 1}
    assert Req.get!(url <> "/metrics", retry: false).status == 200
    assert Req.get!(url <> "/", retry: false).status == 404
    assert Req.post!(url <> "/metrics", retry: false).status == 404
  end

  test "the public site has no metrics page", %{conn: conn} do
    assert get(conn, "/metrics").status == 404
  end

  test "exposes the bounded Privy browser failure counter", %{url: url} do
    :telemetry.execute([:keyfleet, :privy, :browser_failure], %{count: 1}, %{
      reason: "provider_error"
    })

    response = Req.get!(url <> "/metrics", retry: false)

    assert response.body =~ ~s(keyfleet_privy_browser_failure_total{reason="provider_error"})
    assert Req.Response.get_header(response, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "exposes the chain requests that got no answer", %{url: url} do
    :telemetry.execute([:keyfleet, :chain, :failure], %{count: 1}, %{
      method: "eth_getTransactionReceipt",
      class: "timeout",
      chain_id: 1,
      scope: "wallet"
    })

    body = Req.get!(url <> "/metrics", retry: false).body

    assert body =~
             ~s(keyfleet_chain_failure_total{chain_id="1",class="timeout",method="eth_getTransactionReceipt",scope="wallet"})
  end

  test "exposes the keeper's transactions, pauses, balance, spending and reveals", %{url: url} do
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

    body = Req.get!(url <> "/metrics", retry: false).body

    assert body =~ ~s(keyfleet_keeper_tx_total{function="request_reveal",outcome="reverted"})
    assert body =~ ~s(keyfleet_keeper_paused_total{job="income",reason="spend_ceiling"})
    assert body =~ ~r/^keyfleet_keeper_wallet_balance_wei 42$/m
    assert body =~ ~r/^keyfleet_keeper_spent_24h_wei 7$/m

    assert body =~
             ~r/^keyfleet_keeper_vrf_native_balance_wei\{fleet="fleet_tech_classic"\} 30$/m

    assert body =~ ~r/^keyfleet_keeper_reveals_waiting\{fleet="fleet_tech_classic"\} 3$/m
  end
end
