defmodule KeyfleetWeb.Vitals do
  @moduledoc """
  Visitors' own page timings: the Core Web Vitals their browsers measured on
  this site's pages, sent once as a page is left (`assets/js/vitals.ts`, taken
  in by `KeyfleetWeb.BeaconController`). Each report becomes a few numbers in
  the Prometheus histograms `KeyfleetWeb.Telemetry` exports. Nothing is saved,
  and no report names a person, an address or a Key.

  A report names its page by the route pattern the router matched, such as
  `/classic/1/polls/:poll_id`, never by its address, so no Key number, room or
  poll reaches a label. Only the patterns of `KeyfleetWeb.RouteCatalog`, the
  site's pages, are counted. The pattern is the page the visit opened on: live
  navigation keeps the document, so LCP, FCP and TTFB are that page's own, and
  INP and CLS cover the visit from there until the page was first hidden.

  ## Reading p75

  Fly scrapes the private metrics listener (`fly.toml`, `[metrics]`) and adds
  the `app` label. The bucket bounds include each target (LCP 2.5 s, INP
  0.2 s, CLS 0.1), so whether the 75th percentile meets a target is exact: the
  share of page views at or under it, which meets the target from 0.75 up.

      sum(rate(keyfleet_vitals_lcp_microseconds_bucket{app="keyfleet", device="phone", le="2.5e6"}[1h]))
        / sum(rate(keyfleet_vitals_lcp_microseconds_count{app="keyfleet", device="phone"}[1h]))

  The 75th percentile itself, interpolated within its bucket, on phones and
  then by page and device:

      histogram_quantile(0.75,
        sum by (le) (rate(keyfleet_vitals_lcp_microseconds_bucket{app="keyfleet", device="phone"}[1h])))

      histogram_quantile(0.75,
        sum by (le, route, device) (rate(keyfleet_vitals_lcp_microseconds_bucket{app="keyfleet"}[1h])))

  The same with `keyfleet_vitals_inp_microseconds` (`le="2.0e5"`),
  `keyfleet_vitals_cls_thousandths` (`le="100.0"`), `keyfleet_vitals_fcp_microseconds`
  and `keyfleet_vitals_ttfb_microseconds`.
  How many page views stand behind each figure:

      sum by (route, device) (increase(keyfleet_vitals_lcp_microseconds_count{app="keyfleet"}[1h]))

  `keyfleet_vitals_reports_total` counts reports by device and connection
  type, and `keyfleet_vitals_refused_total` the reports refused, by reason.
  """

  alias KeyfleetWeb.RouteCatalog

  @fields ~w(route device connection metrics)
  @devices ~w(phone desktop)
  # `navigator.connection.effectiveType`, where the browser has it.
  @connections ~w(slow-2g 2g 3g 4g)

  # Each metric the browser reports, the event it is counted under, and the
  # most it may be. Times arrive in milliseconds. A value past its bound is a
  # broken or made-up report, not a slow page: a page still loading after a
  # minute is long abandoned, and a layout shift score of 10 means the page
  # moved its whole height ten times over.
  @metrics %{
    "LCP" => {:lcp, 60_000},
    "FCP" => {:fcp, 60_000},
    "TTFB" => {:ttfb, 60_000},
    "INP" => {:inp, 60_000},
    "CLS" => {:cls, 10}
  }

  @doc """
  The route pattern of the page `conn` renders, when it is one of the site's
  pages, for the page to report its timings under; otherwise nil, and the
  page reports nothing.
  """
  def route(conn) do
    case Phoenix.Router.route_info(KeyfleetWeb.Router, "GET", conn.request_path, conn.host) do
      %{route: route} -> if page?(route), do: route
      _other -> nil
    end
  end

  @doc """
  Counts one decoded report, or refuses it whole with `:error`: anything but
  the four fields, a page that is not one of the site's, an unknown device,
  connection or metric, no metric at all, or a value that is not a number
  within its bound.
  """
  def record(%{"route" => route, "device" => device, "metrics" => metrics} = report)
      when device in @devices and is_map(metrics) do
    with true <- page?(route),
         [] <- Map.keys(report) -- @fields,
         {:ok, connection} <- connection(report),
         {:ok, values} <- values(metrics) do
      for {event, value} <- values do
        :telemetry.execute([:keyfleet, :vitals, event], %{value: value}, %{
          route: route,
          device: device
        })
      end

      :telemetry.execute([:keyfleet, :vitals, :report], %{count: 1}, %{
        device: device,
        connection: connection
      })
    else
      _refused -> :error
    end
  end

  def record(_report), do: :error

  # Read when a page reports, not as this module compiles, so the router and
  # its pages don't recompile this module and everything that calls it.
  defp page?(route), do: Enum.any?(RouteCatalog.entries(), &(&1.path_pattern == route))

  defp connection(%{"connection" => connection}) when connection in @connections,
    do: {:ok, connection}

  defp connection(%{"connection" => _unknown}), do: :error
  defp connection(_report), do: {:ok, "unknown"}

  defp values(metrics) when map_size(metrics) > 0 do
    Enum.reduce_while(metrics, {:ok, []}, fn {name, value}, {:ok, values} ->
      case @metrics do
        %{^name => {event, most}} when is_number(value) and value >= 0 and value <= most ->
          {:cont, {:ok, [{event, measure(event, value)} | values]}}

        _unknown_or_out_of_bounds ->
          {:halt, :error}
      end
    end)
  end

  defp values(_none), do: :error

  # The layout shift score has no unit and is exported in thousandths; the
  # times are exported in microseconds.
  defp measure(:cls, score), do: round(score * 1000)
  defp measure(_time, milliseconds), do: round(milliseconds * 1000)
end
