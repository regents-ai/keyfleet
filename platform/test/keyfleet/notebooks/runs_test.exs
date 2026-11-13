defmodule Keyfleet.Notebooks.RunsTest do
  # A notebook's last good page comes from Keyfleet's own copies of its runs'
  # pages, so no number of failed runs after it hides it. The hub is a local
  # server answering one agent's "Agent runs" job as the real one does: runs
  # newest first, each finished run's page with its id, status and time.
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Keyfleet.Notebooks.Runs
  alias KeyfleetWeb.SignedAgentHelpers

  @fleet "fibonacci_syndicate"
  @space "proj-fleet"
  @notebook "nb-0123456789abcdef"
  @subject "kf_agent_runs_test"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    runs = start_supervised!({Agent, fn -> [] end})
    hub = SignedAgentHelpers.serve_ipv6!(:hub, fn conn, _opts -> hub(conn, runs) end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))

    %{runs: runs}
  end

  # Costly failure: a notebook that once worked shows no good result once
  # enough later runs have failed, so its last good page is lost to agents.
  test "the last good page outlasts any number of failed runs after it", %{runs: runs} do
    good = finish(runs, 0, "succeeded")
    assert {:ok, %{result_url: good_url, last_succeeded: nil, failure: nil}} = read(good)
    assert is_binary(good_url)

    failed = for n <- 1..25, do: finish(runs, n, "failed")
    for run_id <- failed, do: assert({:ok, %{status: "failed"}} = read(run_id))

    newest = List.last(failed)
    assert {:ok, answer} = read(newest)
    assert answer.last_succeeded == %{run_id: good, result_url: good_url}
    assert answer.failure == failure(25)
    refute answer.result_url == good_url

    assert {:ok, [listed]} = Runs.list(@fleet, @subject, @space)
    assert listed.last_run.run_id == newest
    assert listed.last_run.status == "failed"
    assert listed.last_succeeded == %{run_id: good, result_url: good_url}
  end

  defp read(run_id), do: Runs.read(@fleet, @subject, @space, @notebook, run_id)

  # Run n finishes with `status`, its page made n seconds after the first's.
  defp finish(runs, n, status) do
    run_id = "run_" <> String.pad_leading(Integer.to_string(n), 26, "0")
    finished_at = DateTime.add(~U[2026-11-13 00:00:00Z], n, :second)

    run =
      %{"run_id" => run_id, "status" => status, "finished_at" => DateTime.to_iso8601(finished_at)}
      |> Map.put("failure", if(status == "failed", do: failure(n)))

    Agent.update(runs, &[run | &1])
    run_id
  end

  defp failure(n),
    do: %{"stage" => "export", "exit_status" => 1, "message" => "run #{n} stopped"}

  defp hub(conn, runs) do
    conn = fetch_query_params(conn)
    newest_first = Agent.get(runs, & &1)
    run = fn run_id -> Enum.find(newest_first, &(&1["run_id"] == run_id)) end

    case conn.path_info do
      ["api", "v1", "projects", @space, "notebooks"] ->
        data(conn, %{"items" => [%{"id" => @notebook, "title" => "Runs", "description" => ""}]})

      ["api", "v1", "projects", @space, "notebooks", @notebook, "jobs"] ->
        data(conn, %{
          "items" => [%{"id" => "job-1", "name" => "Agent runs", "created_by" => @subject}]
        })

      ["api", "v1", "projects", @space, "notebooks", @notebook, "jobs", "job-1", "runs"] ->
        limit = String.to_integer(conn.query_params["limit"])
        data(conn, %{"items" => Enum.take(newest_first, limit)})

      ["api", "v1", "projects", @space, "notebooks", @notebook, "jobs", "job-1", "runs", id] ->
        data(conn, run.(id))

      [
        "api",
        "v1",
        "projects",
        @space,
        "notebooks",
        @notebook,
        "jobs",
        "job-1",
        "runs",
        id,
        "html"
      ] ->
        page(conn, run.(id))
    end
  end

  defp data(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"success" => true, "data" => data}))
  end

  defp page(conn, run) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-marimohub-run-id", run["run_id"])
    |> put_resp_header("x-marimohub-run-status", run["status"])
    |> put_resp_header("x-marimohub-captured-at", run["finished_at"])
    |> send_resp(200, "<p>#{run["run_id"]}</p>")
  end
end
