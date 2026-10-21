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
  Every request the router sends to a page or controller is timed by its route
  pattern (`[:phoenix, :router_dispatch, :stop]`), never by its path, and every
  query by its whole time (`total_time` of the same Ecto event). Each fetch of
  the agent guides (`/skill.md`, `/agents.md`) is one request under its route.
  The engine's memory, run queues and process counts come from telemetry_poller's
  default poller.

  The reporter, Peep, keeps a fixed set of counters for each series and holds
  no observation between scrapes. It adds each observation to a running total
  as a whole number, so times are measured in whole microseconds, the layout
  shift score in thousandths, and every total stays exact.
  """

  import Telemetry.Metrics

  alias KeyfleetWeb.Telemetry.Buckets

  # The reasons the wallet hook reports (`Failure` in send_step.ts). Only these
  # are counted, so a label never holds whatever a browser chose to send.
  @wallet_failures ~w(step_unknown wallet_unavailable network_mismatch wallet_declined insufficient_funds send_unconfirmed)

  @reporter :keyfleet_prometheus

  def child_spec(_arg) do
    Peep.child_spec(metrics: metrics(), name: @reporter)
  end

  @doc "Every measurement as Prometheus text, as the metrics listener answers it."
  def scrape,
    do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export() |> IO.iodata_to_binary()

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
      distribution("health.db_queue.microseconds",
        event_name: [:keyfleet, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :microsecond},
        description: "Microseconds a query waited for a database connection",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000] ++
              [1_000_000, 2_500_000, 5_000_000]
        ]
      ),
      distribution("keyfleet.repo.query.microseconds",
        event_name: [:keyfleet, :repo, :query],
        measurement: :total_time,
        unit: {:native, :microsecond},
        description: "Microseconds each query took, waiting for a connection included",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000] ++
              [1_000_000, 2_500_000, 5_000_000]
        ]
      ),
      distribution("keyfleet.request.duration.microseconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:route],
        description: "Microseconds each request took, by its route pattern",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000] ++
              [2_500_000, 5_000_000, 10_000_000]
        ]
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
      distribution("keyfleet.vitals.lcp.microseconds",
        event_name: [:keyfleet, :vitals, :lcp],
        measurement: :value,
        tags: [:route, :device],
        description: "Largest Contentful Paint visitors' browsers measured",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [500_000, 1_000_000, 1_500_000, 2_000_000, 2_500_000, 3_000_000, 4_000_000] ++
              [5_000_000, 6_000_000, 8_000_000, 10_000_000, 15_000_000, 30_000_000]
        ]
      ),
      distribution("keyfleet.vitals.fcp.microseconds",
        event_name: [:keyfleet, :vitals, :fcp],
        measurement: :value,
        tags: [:route, :device],
        description: "First Contentful Paint visitors' browsers measured",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [250_000, 500_000, 750_000, 1_000_000, 1_250_000, 1_500_000, 1_800_000] ++
              [2_250_000, 3_000_000, 4_000_000, 6_000_000, 10_000_000]
        ]
      ),
      distribution("keyfleet.vitals.ttfb.microseconds",
        event_name: [:keyfleet, :vitals, :ttfb],
        measurement: :value,
        tags: [:route, :device],
        description: "Time to the first byte of the page visitors' browsers measured",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [50_000, 100_000, 200_000, 300_000, 400_000, 500_000, 650_000, 800_000] ++
              [1_000_000, 1_400_000, 1_800_000, 3_000_000, 5_000_000]
        ]
      ),
      distribution("keyfleet.vitals.inp.microseconds",
        event_name: [:keyfleet, :vitals, :inp],
        measurement: :value,
        tags: [:route, :device],
        description: "Interaction to Next Paint visitors' browsers measured",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [25_000, 50_000, 75_000, 100_000, 150_000, 200_000, 300_000, 400_000] ++
              [500_000, 750_000, 1_000_000, 2_000_000]
        ]
      ),
      distribution("keyfleet.vitals.cls.thousandths",
        event_name: [:keyfleet, :vitals, :cls],
        measurement: :value,
        tags: [:route, :device],
        description:
          "Cumulative Layout Shift visitors' browsers measured, in thousandths of a score",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets: [10, 25, 50, 75, 100, 150, 250, 500, 1_000]
        ]
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
      distribution("keyfleet.jobs.duration.microseconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:queue, :worker],
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets: [
            10_000,
            50_000,
            100_000,
            500_000,
            1_000_000,
            5_000_000,
            15_000_000,
            60_000_000
          ]
        ]
      ),
      last_value("vm.memory.total.bytes", event_name: [:vm, :memory], measurement: :total),
      last_value("vm.memory.processes.bytes",
        event_name: [:vm, :memory],
        measurement: :processes
      ),
      last_value("vm.memory.binary.bytes", event_name: [:vm, :memory], measurement: :binary),
      last_value("vm.memory.ets.bytes", event_name: [:vm, :memory], measurement: :ets),
      last_value("vm.memory.code.bytes", event_name: [:vm, :memory], measurement: :code),
      last_value("vm.memory.atom.bytes", event_name: [:vm, :memory], measurement: :atom),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count")
    ]
  end
end
