defmodule KeyfleetWeb.HealthController do
  @moduledoc "`/healthz`: \"ok\" only while the site's own database answers."
  use KeyfleetWeb, :controller

  def show(conn, _params) do
    {status, body} =
      if database_ready?(), do: {:ok, "ok"}, else: {:service_unavailable, "unavailable"}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  # A running server alone does not make the site ready: read one of the site's
  # own tables without returning rows. The timeout is below Fly's two-second
  # health deadline, and no error or connection detail leaves this endpoint. The
  # schema is the repository's own configured name, never request input.
  # sobelow_skip ["SQL.Query"]
  defp database_ready? do
    sql = "SELECT 1 FROM \"#{Keyfleet.Repo.default_prefix()}\".session_authorities LIMIT 0"

    match?(
      {:ok, _},
      Ecto.Adapters.SQL.query(Keyfleet.Repo, sql, [], timeout: 1_000, log: false)
    )
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
