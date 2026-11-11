defmodule KeyfleetWeb.SharedReadingStartTest do
  # Costly failure: during a deploy the database is slow, each shared reading
  # waits for its fleets one after another, and the site misses Fly's 30 s
  # grace and is never released.
  use KeyfleetWeb.ConnCase, async: false

  # Every read that waits too long is saved with the site's errors, here as log lines.
  @moduletag :capture_log

  alias Keyfleet.Repo
  alias KeyfleetWeb.{FleetNow, FleetProposals}

  for producer <- [FleetNow, FleetProposals] do
    test "#{inspect(producer)} starts within one wait while every read hangs" do
      # A start much longer than the first read's own wait waited for more
      # than one fleet in turn.
      wait = Application.fetch_env!(:keyfleet, :first_read_ms)
      holding = hold_database(wait + 1_500)

      {started_in, _pid} = :timer.tc(fn -> start_supervised!(unquote(producer)) end, :millisecond)

      assert started_in < wait + 500
      Task.await(holding, 10_000)
    end
  end

  # Keeps the test's one database connection busy for `ms`, so every read
  # waits for it.
  defp hold_database(ms) do
    test = self()

    holding =
      Task.async(fn ->
        Repo.checkout(fn ->
          send(test, :holding)
          Repo.query!("SELECT pg_sleep($1)", [ms / 1_000])
        end)
      end)

    assert_receive :holding
    holding
  end
end
