defmodule KeyfleetWeb.ChainNumbersTest do
  # Sentinel reads these from the site's metrics listener (fly-sentinel
  # docs/metrics-contract.md). Keyfleet sends from no wallet of its own, so a
  # query stands in for one here.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias KeyfleetWeb.Telemetry

  test "a reader's pass sets its lag in blocks and counts the pass" do
    for blocks <- [12, 3] do
      :telemetry.execute([:keyfleet, :indexer, :lag], %{blocks: blocks}, %{
        indexer: "test_reader",
        chain_id: 84_532
      })
    end

    labels = [~s(indexer="test_reader"), ~s(chain_id="84532")]
    assert value("health_indexer_lag_blocks", labels) == 3
    assert value("health_indexer_passes_total", labels) == 2
  end

  test "a fleet stopped at a disagreement is counted until it is cleared" do
    :ok = Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()

    Telemetry.count_fleets_stopped()
    before = value("keyfleet_fleets_stopped", [])

    ChainHelpers.seed_cursor!("fleet_tech_accelerant", rescan_from: 900)
    Telemetry.count_fleets_stopped()

    assert value("keyfleet_fleets_stopped", []) == before + 1
  end

  test "a site's query of its own sends sets each flow's oldest age, 0 when none waits" do
    signed_at = DateTime.add(DateTime.utc_now(), -90, :second)

    assert :ok = Telemetry.oldest_unconfirmed_sends({__MODULE__, :sends, [signed_at]})

    assert value("health_wallet_unconfirmed_oldest_seconds", [~s(flow="test_waiting")]) >= 90
    assert value("health_wallet_unconfirmed_oldest_seconds", [~s(flow="test_none")]) == 0
  end

  test "a query that fails is logged and the tick skipped" do
    log =
      capture_log(fn ->
        assert :ok = Telemetry.oldest_unconfirmed_sends({__MODULE__, :unanswered, []})
      end)

    assert log =~ "unconfirmed send age not measured: no answer"
  end

  test "Keyfleet names no query of its own sends, so it never publishes their age" do
    {:telemetry_poller, opts} = Telemetry.site_poller()

    refute Enum.any?(opts[:measurements], &match?({Telemetry, :oldest_unconfirmed_sends, _}, &1))
  end

  def sends(signed_at), do: [{"test_waiting", signed_at}, {"test_none", nil}]

  def unanswered, do: raise("no answer")

  defp value(name, labels) do
    Telemetry.scrape()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      with [series, number] <- String.split(line, " "),
           true <- series == name or String.starts_with?(series, name <> "{"),
           true <- Enum.all?(labels, &String.contains?(series, &1)) do
        {number, ""} = Float.parse(number)
        number
      else
        _ -> nil
      end
    end)
  end
end
