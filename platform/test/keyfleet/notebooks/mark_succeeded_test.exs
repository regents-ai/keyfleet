defmodule Keyfleet.Notebooks.MarkSucceededTest do
  # Copies of run pages kept before each copy recorded whether its run
  # succeeded are marked once from the fleet's hub, so a notebook's last good
  # page is there on the release day. The hub is a local server answering as
  # the real one does: the project's notebooks, a notebook's jobs, and the runs
  # it still holds with their status.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.ChainHelpers
  alias Keyfleet.{Fleets, Notebooks, Projects}
  alias Keyfleet.Notebooks.MarkSucceeded
  alias KeyfleetWeb.SignedAgentHelpers

  @fleet "fleet_tech_classic"
  @space "proj-scratch"
  @notebook "nb-0123456789abcdef"
  @good "run_" <> String.duplicate("1", 26)
  @failed "run_" <> String.duplicate("2", 26)
  @gone "run_" <> String.duplicate("3", 26)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])

    @fleet
    |> Projects.project!("scratchpad", actor: %System{})
    |> Projects.record_space!(@space, actor: %System{})

    hub = SignedAgentHelpers.serve_ipv6!(:hub, fn conn, _opts -> hub(conn) end)
    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))
    :ok
  end

  # Costly failure: a notebook's last good page gone on the release day, or a
  # failed run's page shown as its last good one.
  test "marks the copies of runs the hub names succeeded, and changes nothing else" do
    for {run_id, n} <- Enum.with_index([@good, @failed, @gone], 1) do
      Notebooks.keep_saved_output!(@fleet, @notebook, run_id, n, "<p>#{run_id}</p>", false,
        actor: %System{}
      )
    end

    assert last_succeeded() == []

    assert {:ok, 1} = MarkSucceeded.backfill()
    assert {:ok, 1} = MarkSucceeded.backfill()
    assert [%{args: %{"fleet_id" => @fleet}}] = all_enqueued(worker: MarkSucceeded)

    before = copies()
    assert :ok = perform_job(MarkSucceeded, %{fleet_id: @fleet})
    assert :ok = perform_job(MarkSucceeded, %{fleet_id: @fleet})

    assert copies() ==
             Enum.map(before, fn
               %{source_id: @good} = copy -> %{copy | succeeded: true}
               copy -> copy
             end)

    assert [%{source_id: @good, saved_at: 1}] = last_succeeded()
  end

  # A copy is plain, succeeded or failed, never succeeded with a failure
  # recorded: marking leaves a copy that records how its run failed as it
  # is, recording a failure leaves one marked succeeded as it is, and neither
  # is an error, saved or answered. The database refuses the row outright.
  test "a copy is never marked succeeded and failed at once" do
    stopped = %{"stage" => "export", "message" => "Stopped."}

    for {run_id, n, succeeded} <- [{@good, 1, false}, {@gone, 3, true}] do
      Notebooks.keep_saved_output!(@fleet, @notebook, run_id, n, "<p>#{run_id}</p>", succeeded,
        actor: %System{}
      )
    end

    assert :ok = Notebooks.record_run_failure(@fleet, @good, stopped)
    errors = saved_errors()

    # The hub names @good succeeded, though its copy records how it failed.
    assert :ok = perform_job(MarkSucceeded, %{fleet_id: @fleet})
    assert :ok = Notebooks.record_run_failure(@fleet, @gone, stopped)

    assert outcomes([{@good, 1}, {@gone, 3}]) == [
             %{
               source_id: @good,
               succeeded: false,
               failure: %{stage: "export", message: "Stopped."}
             },
             %{source_id: @gone, succeeded: true, failure: nil}
           ]

    assert saved_errors() == errors

    assert_raise Postgrex.Error, ~r/notebook_saved_outputs_succeeded_or_failed/, fn ->
      Keyfleet.Repo.query!(
        "UPDATE keyfleet_app.notebook_saved_outputs SET succeeded = true WHERE source_id = $1",
        [@good]
      )
    end
  end

  defp copies do
    for {run_id, n} <- Enum.with_index([@good, @failed, @gone], 1) do
      @fleet
      |> Notebooks.saved_output!(@notebook, run_id, n, actor: %System{})
      |> Map.take([:id, :notebook_id, :source_id, :saved_at, :page, :succeeded])
    end
  end

  defp outcomes(kept) do
    for {run_id, n} <- kept do
      @fleet
      |> Notebooks.saved_output!(@notebook, run_id, n, actor: %System{})
      |> Map.take([:source_id, :succeeded, :failure])
    end
  end

  # Saved errors are ErrorTracker's own table, which no Ash resource reads.
  defp saved_errors, do: Keyfleet.Repo.aggregate(ErrorTracker.Occurrence, :count)

  defp last_succeeded,
    do: Notebooks.last_succeeded_outputs!(@fleet, [@notebook], actor: %System{})

  # A second notebook has no copies, so the hub is never asked for its jobs.
  defp hub(conn) do
    case conn.path_info do
      ["api", "v1", "projects", @space, "notebooks"] ->
        data(conn, [%{"id" => @notebook}, %{"id" => "nb-fedcba9876543210"}])

      ["api", "v1", "projects", @space, "notebooks", @notebook, "jobs"] ->
        data(conn, [%{"id" => "job-1"}])

      ["api", "v1", "projects", @space, "notebooks", @notebook, "jobs", "job-1", "runs"] ->
        data(conn, [
          %{"run_id" => @failed, "status" => "failed"},
          %{"run_id" => @good, "status" => "succeeded"}
        ])
    end
  end

  defp data(conn, items) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{"success" => true, "data" => %{"items" => items, "next_cursor" => nil}})
    )
  end
end
