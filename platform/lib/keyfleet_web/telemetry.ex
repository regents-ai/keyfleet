defmodule KeyfleetWeb.Telemetry do
  @moduledoc """
  The site's measurements, as `:telemetry` events, and their Prometheus export on
  the private metrics listener (`KeyfleetWeb.Metrics`). Fly Sentinel's site
  watch reads the three `health.*` series from every site: Ecto's
  `[:keyfleet, :repo, :query]` (`queue_time` is the wait for a connection),
  `[:keyfleet, :chain, :failure]` for each chain request that got no answer
  (`Keyfleet.ChainClient`), and `[:keyfleet, :wallet, :failure]` for each
  press the browser reported as not sent or not confirmed (`wallet_failed/2`).
  The figures every visitor sees alike (`Keyfleet.SharedReading`) report, for
  each kind, how many keys are held, how many have never been read, how long ago
  the oldest was read, each reading that could not be taken and each one refused.
  Visitors' browsers report each page's Core Web Vitals (`KeyfleetWeb.Vitals`,
  which also gives the queries for their 75th percentiles), one histogram for
  each with buckets around its targets, by page and device.
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

  @doc "The poller for the measurements the site takes itself."
  def site_poller,
    do:
      {:telemetry_poller,
       measurements: [{Keyfleet.SharedReading, :measure, []}],
       period: 10_000,
       name: :keyfleet_site_poller}

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
      ),
      last_value("health.shared_reading.oldest.seconds",
        event_name: [:keyfleet, :shared_reading, :kind],
        measurement: :oldest_seconds,
        tags: [:kind],
        description: "Seconds since the oldest shared reading of each kind was read"
      ),
      last_value("health.shared_reading.late.keys",
        event_name: [:keyfleet, :shared_reading, :kind],
        measurement: :late,
        tags: [:kind],
        description: "Keys of the kind last read longer ago than the kind's producer should allow"
      ),
      last_value("health.shared_reading.never_read.keys",
        event_name: [:keyfleet, :shared_reading, :kind],
        measurement: :never_read,
        tags: [:kind],
        description: "Keys of the kind that have had no reading since the site started"
      ),
      counter("health.agent_activity_unread.total",
        event_name: [:keyfleet, :agents, :activity_unread],
        tags: [:reason],
        description: "Agents' activity reads from the sign-in service that gave no reading"
      ),
      counter("health.shared_reading.degraded.total",
        event_name: [:keyfleet, :shared_reading, :degraded],
        tags: [:kind],
        description: "Shared readings that could not be taken"
      ),
      last_value("keyfleet.shared_reading.keys",
        event_name: [:keyfleet, :shared_reading, :kind],
        measurement: :keys,
        tags: [:kind]
      ),
      last_value("keyfleet.shared_reading.table.bytes",
        event_name: [:keyfleet, :shared_reading, :table],
        measurement: :bytes
      ),
      counter("keyfleet.shared_reading.refused.total",
        event_name: [:keyfleet, :shared_reading, :refused],
        tags: [:kind, :reason]
      ),
      counter("keyfleet.shared_reading.woken.total",
        event_name: [:keyfleet, :shared_reading, :woken],
        tags: [:kind]
      ),
      # Visitors' page timings (KeyfleetWeb.Vitals). Each metric has its own
      # buckets, finest around Google's "good" and "poor" bounds, and each
      # target (LCP 2.5 s, INP 0.2 s, CLS 0.1) is a bucket bound, so the share
      # of page views within it is exact. Labels are only the site's route
      # patterns and two devices.
      distribution("keyfleet.vitals.lcp.seconds",
        event_name: [:keyfleet, :vitals, :lcp],
        measurement: :value,
        tags: [:route, :device],
        description: "Largest Contentful Paint visitors' browsers measured",
        reporter_options: [buckets: [0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 15, 30]]
      ),
      distribution("keyfleet.vitals.fcp.seconds",
        event_name: [:keyfleet, :vitals, :fcp],
        measurement: :value,
        tags: [:route, :device],
        description: "First Contentful Paint visitors' browsers measured",
        reporter_options: [buckets: [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.8, 2.25, 3, 4, 6, 10]]
      ),
      distribution("keyfleet.vitals.ttfb.seconds",
        event_name: [:keyfleet, :vitals, :ttfb],
        measurement: :value,
        tags: [:route, :device],
        description: "Time to the first byte of the page visitors' browsers measured",
        reporter_options: [buckets: [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 1, 1.4, 1.8, 3, 5]]
      ),
      distribution("keyfleet.vitals.inp.seconds",
        event_name: [:keyfleet, :vitals, :inp],
        measurement: :value,
        tags: [:route, :device],
        description: "Interaction to Next Paint visitors' browsers measured",
        reporter_options: [
          buckets: [0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2]
        ]
      ),
      distribution("keyfleet.vitals.cls",
        event_name: [:keyfleet, :vitals, :cls],
        measurement: :value,
        tags: [:route, :device],
        description: "Cumulative Layout Shift visitors' browsers measured, a score with no unit",
        reporter_options: [buckets: [0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.25, 0.5, 1]]
      ),
      counter("keyfleet.vitals.reports.total",
        event_name: [:keyfleet, :vitals, :report],
        tags: [:device, :connection],
        description: "Page timing reports counted, by device and the browser's connection type"
      ),
      counter("keyfleet.vitals.refused.total",
        event_name: [:keyfleet, :vitals, :refused],
        tags: [:reason],
        description: "Page timing reports refused: rate_limited, too_large or invalid"
      ),
      # Background jobs report each run's outcome and time from Oban's own events.
      counter("keyfleet.jobs.finished.total",
        event_name: [:oban, :job, :stop],
        tags: [:queue, :worker, :state],
        description: "Job runs that ended done, cancelled or snoozed"
      ),
      counter("keyfleet.jobs.failed.total",
        event_name: [:oban, :job, :exception],
        tags: [:queue, :worker, :state],
        description: "Job runs that failed; state says whether the job will retry"
      ),
      distribution("keyfleet.jobs.duration.seconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:queue, :worker],
        reporter_options: [buckets: [0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60]]
      )
    ]
  end
end
