defmodule KeyfleetWeb.BeaconController do
  @moduledoc """
  Reports a visitor's browser sends with `navigator.sendBeacon`:
  `POST /vitals`, one page's timings as the page is left (counted by
  `KeyfleetWeb.Vitals`), and `POST /steps`, one step a visitor took into
  Keyfleet (counted by `KeyfleetWeb.LaunchSteps`). The browser never reads the
  answer: 204 when counted, 400 when refused, 413 past the size of a report and
  429 past the address's budget.

  It runs with no session and no CSRF token. `sendBeacon` cannot send the
  token's header, and nothing here needs one: the request reads no session,
  account or cookie, writes nothing anyone reads back and can only add bounded
  numbers under fixed labels to the timing histograms or the step counters. A
  page on another site that has a browser post here can do nothing more than
  anyone can do by posting here directly, and both spend the same per-address
  budget.

  The address is used only as that budget's key, which lives in the limiter
  alone (`KeyfleetWeb.ClientAddress`); it is never logged, saved or counted.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Accounts.RequestRateLimiter
  alias KeyfleetWeb.{ClientAddress, LaunchSteps, Vitals}

  # Reports per client address each minute, for each kind. A page view sends
  # one timing report and a visit a few steps, so this leaves room for many
  # people behind one address; past it, a report is dropped.
  @limit 60
  @window_seconds 60

  # A timing report is about 250 bytes, so a body past a kilobyte is not one.
  def vitals(conn, _params),
    do: take(conn, Vitals, :vitals, [:keyfleet, :vitals, :refused], 1024)

  # A step is under 50 bytes, so a body past 256 is not one.
  def steps(conn, _params),
    do: take(conn, LaunchSteps, :launch_steps, [:keyfleet, :launch, :refused], 256)

  # The browser sends a report as text/plain, which the endpoint's parsers
  # leave unread, so the body limit here is the only read. Every answer goes
  # out on the connection the read returned.
  defp take(conn, recorder, budget, refused, body_limit) do
    {key, _source} = ClientAddress.key(conn)

    with {:ok, _budget} <- RequestRateLimiter.admit({budget, key}, @limit, @window_seconds),
         {:ok, body, conn} <- read_body(conn, length: body_limit, read_length: body_limit) do
      with {:ok, report} <- Jason.decode(body),
           :ok <- recorder.record(report) do
        send_resp(conn, :no_content, "")
      else
        _invalid -> refuse(conn, refused, :invalid, :bad_request)
      end
    else
      {:error, :rate_limited, budget} ->
        conn
        |> put_resp_header("retry-after", to_string(budget.reset))
        |> refuse(refused, :rate_limited, :too_many_requests)

      {:more, _partial, conn} ->
        refuse(conn, refused, :too_large, :request_entity_too_large)

      {:error, _unreadable} ->
        refuse(conn, refused, :invalid, :bad_request)
    end
  end

  defp refuse(conn, event, reason, status) do
    :telemetry.execute(event, %{count: 1}, %{reason: reason})
    send_resp(conn, status, "")
  end
end
