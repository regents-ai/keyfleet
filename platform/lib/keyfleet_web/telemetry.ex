defmodule KeyfleetWeb.Telemetry do
  @moduledoc """
  The site's measurements, as `:telemetry` events, and their Prometheus export on
  the private metrics listener (`KeyfleetWeb.Metrics`). Fly Sentinel's site
  watch reads the three `health.*` series from every site: Ecto's
  `[:keyfleet, :repo, :query]` (`queue_time` is the wait for a connection),
  `[:keyfleet, :chain, :failure]` for each chain request that got no answer
  (`Keyfleet.ChainClient`), and `[:keyfleet, :wallet, :failure]` for each
  press the browser reported as not sent or not confirmed (`wallet_failed/2`).
  The figures every reader they admit sees alike (`Keyfleet.SharedReading`)
  report, for each kind, how many keys are held, how many have never been read,
  how long ago the oldest was read, the size of each reading offered as a percent
  of its kind's limit, each reading that could not be taken and each one refused.
  Visitors' browsers report each page's Core Web Vitals (`KeyfleetWeb.Vitals`,
  which also gives the queries for their 75th percentiles), one histogram for
  each with buckets around its targets, by page and device.
  Every request the router sends to a page or controller is timed by its route
  pattern (`[:phoenix, :router_dispatch, :stop]`), never by its path, and every
  query by its whole time (`total_time` of the same Ecto event). Each fetch of
  the agent guides (`/skill.md`, `/agents.md`) is one request under its route.
  Each pass of a fleet's chain reader (`Keyfleet.Chain.ReadFleet`) reports
  `[:keyfleet, :indexer, :lag]`: `blocks` between the head it follows and the
  last block it has read, for its fixed `indexer` name and `chain_id` (the
  chain-events skill). Every ten seconds the site poller counts the fleets
  stopped at a disagreement (`[:keyfleet, :fleets, :stopped]`). A site that sends
  from its own wallet names, as `unconfirmed_sends` in
  `config :keyfleet, KeyfleetWeb.Telemetry`, the function that answers each of its
  fixed sending flows with when its oldest signed, unconfirmed transaction was
  signed, or nil; every ten seconds `[:keyfleet, :wallet, :unconfirmed_oldest]`
  carries that `age_ms` for each `flow`, 0 when none waits. Keyfleet sends from
  no wallet of its own, so it names no query and that age is not reported.
  The engine's memory, run queues and process counts come from telemetry_poller's
  default poller.

  The reporter, Peep, keeps a fixed set of counters for each series and holds
  no observation between scrapes. It adds each observation to a running total
  as a whole number, so times are measured in whole microseconds, the layout
  shift score in thousandths, and every total stays exact.
  """

  import Telemetry.Metrics

  require Logger

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
       measurements:
         [
           {Keyfleet.SharedReading, :measure, []},
           {__MODULE__, :fleets_stopped, []}
         ] ++ unconfirmed_sends_step(),
       period: 10_000,
       name: :keyfleet_site_poller}

  # Only a site that sends from its own wallet names its query. Without one the
  # age is never published, so Sentinel never reads a steady 0 that only means
  # nothing was asked.
  defp unconfirmed_sends_step do
    case Application.get_env(:keyfleet, __MODULE__)[:unconfirmed_sends] do
      nil -> []
      query -> [{__MODULE__, :oldest_unconfirmed_sends, [query]}]
    end
  end

  # The poller drops for good a measurement that raises or exits, and the row
  # would then keep its last number. So whatever stops this tick (a database
  # that cannot answer, Oban not running) is logged and the tick is skipped; the
  # next one tries again. Fleets are counted only where the chain queue runs, so
  # nothing is read where no queue runs (tests).
  @doc false
  def fleets_stopped do
    if Enum.any?(Oban.check_all_queues(), &(&1.queue == "chain")), do: count_fleets_stopped()
    :ok
  rescue
    error -> not_measured("stopped fleets", Exception.message(error))
  catch
    :exit, reason -> not_measured("stopped fleets", Exception.format_exit(reason))
  end

  @doc false
  def count_fleets_stopped do
    stopped = Keyfleet.Chain.Cursor |> Ash.Query.for_read(:stopped) |> Ash.count!()
    :telemetry.execute([:keyfleet, :fleets, :stopped], %{count: stopped}, %{})
  end

  # The site's query, `{module, function, args}`, answers `{flow, signed_at}`
  # for each of its sending flows, `signed_at` nil when nothing waits. Logged
  # and skipped like the job age.
  @doc false
  def oldest_unconfirmed_sends({module, function, args}) do
    now = DateTime.utc_now()

    for {flow, signed_at} <- apply(module, function, args) do
      age_ms =
        case signed_at do
          nil -> 0
          signed_at -> DateTime.diff(now, signed_at, :millisecond)
        end

      :telemetry.execute([:keyfleet, :wallet, :unconfirmed_oldest], %{age_ms: age_ms}, %{
        flow: flow
      })
    end

    :ok
  rescue
    error -> not_measured("unconfirmed send age", Exception.message(error))
  catch
    :exit, reason -> not_measured("unconfirmed send age", Exception.format_exit(reason))
  end

  defp not_measured(what, why), do: Logger.warning("#{what} not measured: #{why}")

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
      last_value("health.indexer.lag.blocks",
        event_name: [:keyfleet, :indexer, :lag],
        measurement: :blocks,
        tags: [:indexer, :chain_id],
        description:
          "Blocks between the chain head a reader follows and the last block it has read"
      ),
      counter("health.indexer.passes.total",
        event_name: [:keyfleet, :indexer, :lag],
        tags: [:indexer, :chain_id],
        description: "Passes each chain reader made"
      ),
      last_value("health.wallet_unconfirmed_oldest.seconds",
        event_name: [:keyfleet, :wallet, :unconfirmed_oldest],
        measurement: :age_ms,
        unit: {:millisecond, :second},
        tags: [:flow],
        description:
          "Age of the oldest transaction the site's own wallet signed that is not yet confirmed"
      ),
      last_value("keyfleet.fleets_stopped",
        event_name: [:keyfleet, :fleets, :stopped],
        measurement: :count,
        description: "Fleets stopped right now"
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
      last_value("health.shared_reading.size.percent",
        event_name: [:keyfleet, :shared_reading, :size],
        measurement: &div(&1.bytes * 100, &1.limit),
        tags: [:kind],
        description:
          "Size of the last reading each kind was offered, as a percent of the kind's limit; " <>
            "past 100 it is refused and the last one held stays"
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
      # Steps visitors take into Keyfleet (KeyfleetWeb.LaunchSteps). Labels are
      # only the step's name and, for a copied setup line, the agent's.
      counter("keyfleet.launch.steps.total",
        event_name: [:keyfleet, :launch, :step],
        tags: [:step],
        description: "Steps into Keyfleet: home opened, watch or connect pressed"
      ),
      counter("keyfleet.launch.setup_copied.total",
        event_name: [:keyfleet, :launch, :setup_copied],
        tags: [:agent],
        description: "Setup lines copied, by the agent they are for"
      ),
      counter("keyfleet.launch.refused.total",
        event_name: [:keyfleet, :launch, :refused],
        tags: [:reason],
        description: "Step reports refused: rate_limited, too_large or invalid"
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
