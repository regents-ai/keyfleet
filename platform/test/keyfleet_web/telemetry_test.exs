defmodule KeyfleetWeb.TelemetryTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Repo

  # Every site's dashboard reads request and query time by these names, so a
  # request and a query must each land in the scrape.
  test "a request is timed by its route pattern and a query by its whole time" do
    :ok = Sandbox.checkout(Repo)

    :get |> conn("/sitemap.xml") |> KeyfleetWeb.Endpoint.call(KeyfleetWeb.Endpoint.init([]))
    Repo.query!("SELECT 1")

    scrape = KeyfleetWeb.Telemetry.scrape()

    assert scrape =~
             ~r/^keyfleet_request_duration_microseconds_count\{route="\/sitemap.xml"\} [1-9]/m

    assert scrape =~ ~r/^keyfleet_repo_query_microseconds_count [1-9]/m
  end

  # The wallet hook reports a signature the wallet may have made apart from a
  # send that may have gone, and each is counted under its own reason.
  test "a press the wallet may have sent or signed is counted by which" do
    for reason <- ~w(send_unconfirmed sign_unconfirmed) do
      KeyfleetWeb.Telemetry.wallet_failed(:telemetry_test, reason)
    end

    scrape = KeyfleetWeb.Telemetry.scrape()

    for reason <- ~w(send_unconfirmed sign_unconfirmed) do
      assert scrape =~
               ~r/^health_wallet_send_failures_total\{flow="telemetry_test",reason="#{reason}"\} [1-9]/m
    end
  end
end
