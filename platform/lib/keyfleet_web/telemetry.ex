defmodule KeyfleetWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core,
       metrics: prometheus_metrics(), name: prometheus_reporter(), start_async: false},
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def prometheus_reporter, do: :keyfleet_prometheus

  def prometheus_metrics do
    [
      counter("keyfleet.privy.browser_failure.total", tags: [:reason]),
      # Each keeper transaction's outcome, each time the keeper stopped or
      # paused sending, its wallet's balance and last 24 hours' spending, and
      # for each fleet its VRF subscription's balance and how many of the
      # keys the reveal job last looked at have waited long for a seed.
      counter("keyfleet.keeper.tx.total", tags: [:function, :outcome]),
      counter("keyfleet.keeper.paused.total", tags: [:job, :reason]),
      last_value("keyfleet.keeper.wallet_balance_wei"),
      last_value("keyfleet.keeper.spent_24h_wei"),
      last_value("keyfleet.keeper.vrf.native_balance_wei", tags: [:fleet]),
      last_value("keyfleet.keeper.reveals.waiting", tags: [:fleet])
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {KeyfleetWeb, :count_users, []}
    ]
  end
end
