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
      chain_id: 8453,
      scope: "wallet"
    })

    body = Req.get!(url <> "/metrics", retry: false).body

    assert body =~
             ~s(health_chain_request_failures_total{chain_id="8453",class="timeout",method="eth_getTransactionReceipt",scope="wallet"})
  end

  test "exposes the steps into Keyfleet under their names only", %{url: url} do
    :telemetry.execute([:keyfleet, :launch, :step], %{count: 1}, %{step: "watch"})
    :telemetry.execute([:keyfleet, :launch, :setup_copied], %{count: 1}, %{agent: "any"})

    body = Req.get!(url <> "/metrics", retry: false).body

    assert body =~ ~s(keyfleet_launch_steps_total{step="watch"})
    assert body =~ ~s(keyfleet_launch_setup_copied_total{agent="any"})
  end
end
