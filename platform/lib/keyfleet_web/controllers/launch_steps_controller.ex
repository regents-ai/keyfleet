defmodule KeyfleetWeb.LaunchStepsController do
  @moduledoc """
  `POST /steps`: one step a visitor took into Keyfleet, sent by the browser
  with `navigator.sendBeacon` and counted by `KeyfleetWeb.LaunchSteps`. The
  browser never reads the answer: 204 when counted, 400 when refused, 413 past
  the size of a report and 429 past the address's budget.

  Like `KeyfleetWeb.VitalsController`, it runs with no session and no CSRF
  token: `sendBeacon` cannot send the token's header, and the request reads no
  session, account or cookie and can only add one to a counter under fixed
  labels. The address is used only as the budget's key, which lives in the
  limiter alone (`KeyfleetWeb.ClientAddress`); it is never logged, saved or
  counted.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Accounts.RequestRateLimiter
  alias KeyfleetWeb.{ClientAddress, LaunchSteps}

  # A report is under 50 bytes, so a body past 256 is not one. The browser
  # sends it as text/plain, which the endpoint's parsers leave unread, so this
  # limit is the only read.
  @body_limit 256

  # Reports per client address each minute. A visit sends a few, so this
  # leaves room for many people behind one address; past it, a report is
  # dropped.
  @limit 60
  @window_seconds 60

  def create(conn, _params) do
    case admit(conn) do
      :ok ->
        read_report(conn)

      {:limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> refuse(:rate_limited, :too_many_requests)
    end
  end

  # Every answer goes out on the connection the read returned.
  defp read_report(conn) do
    case read_body(conn, length: @body_limit, read_length: @body_limit) do
      {:ok, body, conn} ->
        case record(body) do
          :ok -> send_resp(conn, :no_content, "")
          :error -> refuse(conn, :invalid, :bad_request)
        end

      {:more, _partial, conn} ->
        refuse(conn, :too_large, :request_entity_too_large)

      {:error, _reason} ->
        refuse(conn, :invalid, :bad_request)
    end
  end

  defp record(body) do
    case Jason.decode(body) do
      {:ok, report} -> LaunchSteps.record(report)
      {:error, _not_json} -> :error
    end
  end

  defp admit(conn) do
    {key, _source} = ClientAddress.key(conn)

    case RequestRateLimiter.admit({:launch_steps, key}, @limit, @window_seconds) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, budget} -> {:limited, budget.reset}
    end
  end

  defp refuse(conn, reason, status) do
    :telemetry.execute([:keyfleet, :launch, :refused], %{count: 1}, %{reason: reason})
    send_resp(conn, status, "")
  end
end
