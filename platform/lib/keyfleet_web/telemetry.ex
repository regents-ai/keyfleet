defmodule KeyfleetWeb.Telemetry do
  @moduledoc """
  The site's measurements, as `:telemetry` events, and their Prometheus export on
  the private metrics listener (`KeyfleetWeb.Metrics`). Fly Sentinel's site
  watch reads the three `health.*` series from every site: Ecto's
  `[:keyfleet, :repo, :query]` (`queue_time` is the wait for a connection),
  `[:keyfleet, :chain, :failure]` for each chain request that got no answer
  (`Keyfleet.ChainClient`), and `[:keyfleet, :wallet, :failure]` for each
  press the browser reported as not sent or not confirmed (`wallet_failed/2`).
  """

  import Telemetry.Metrics

  # The reasons the wallet hook reports (`Failure` in send_step.ts). Only these
  # are counted, so a label never holds whatever a browser chose to send.
  @wallet_failures ~w(step_unknown wallet_unavailable network_mismatch wallet_declined insufficient_funds send_unconfirmed)

  def child_spec(_arg) do
    TelemetryMetricsPrometheus.Core.child_spec(
      metrics: metrics(),
      name: prometheus_reporter(),
      start_async: false
    )
  end

  def prometheus_reporter, do: :keyfleet_prometheus

  @doc """
  Counts one press the browser reported as not sent or not confirmed, for the
  wallet flow `flow`. A reason the hook never sends is not counted.
  """
  def wallet_failed(flow, reason) when reason in @wallet_failures do
    :telemetry.execute([:keyfleet, :wallet, :failure], %{count: 1}, %{
      flow: flow,
      reason: reason
    })
  end

  def wallet_failed(_flow, _reason), do: :ok

  defp metrics do
    [
      counter("keyfleet.privy.browser_failure.total", tags: [:reason]),
      counter("keyfleet.privy.session_refused.total", tags: [:stage, :reason]),
      counter("keyfleet.session_bootstrap.rate_limited.total", tags: [:source]),
      counter("keyfleet.session_authority.absent_row.total"),
      distribution("health.db_queue.seconds",
        event_name: [:keyfleet, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        description: "Seconds a query waited for a database connection",
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
      ),
      counter("health.chain_request_failures.total",
        event_name: [:keyfleet, :chain, :failure],
        tags: [:method, :class, :chain_id, :scope],
        description: "Chain requests that got no answer"
      ),
      counter("health.wallet_send_failures.total",
        event_name: [:keyfleet, :wallet, :failure],
        tags: [:flow, :reason],
        description: "Wallet presses the browser reported as not sent or not confirmed"
      )
    ]
  end
end
