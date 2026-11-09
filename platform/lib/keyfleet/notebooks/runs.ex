defmodule Keyfleet.Notebooks.Runs do
  @moduledoc """
  A fleet's notebooks, and background runs of them, that an agent lists,
  starts and reads through its own signed requests to this site
  (`KeyfleetWeb.AgentToolController`), so it never signs a request for
  the notebook host itself.

  The hub is asked as the agent (`Keyfleet.Notebooks.MemberRequest`), so a
  run is the agent's, in its own job for the notebook, "Agent runs", made the
  first time it starts a run there. A run works through the notebook's saved
  code, top to bottom, in a fresh sandbox, and never changes the notebook.

  Reading a finished run keeps its page and answers the saved result's
  address (`Keyfleet.Notebooks.result_url/4`), as reading that page on the
  notebook host does (`KeyfleetWeb.Plugs.NotebookGateway`): an address is
  never handed out for a page Keyfleet hasn't kept. Listing the notebooks
  keeps no page: it answers each one's newest run in the agent's own "Agent
  runs" with `result_url` once that run's page has been kept.

  A run started here records what it ran from (`Keyfleet.Notebooks.RunSource`):
  the sha256 of the notebook's saved code just before it started, and the
  entries at the top of its files. Reading the run answers that `source`;
  once the run has finished, `code_current`, whether the notebook's saved
  code is still that code; and while the run hasn't succeeded,
  `last_succeeded`, the newest run of the same job that did, with its saved
  result's address once Keyfleet keeps it, so a pending or failed run never
  hides the last good result.

  Each answer is `{:ok, run}`, with the notebook, the run and its status and,
  once its page is kept, `result_url`, or `{:ok, notebooks}` for a listing;
  or `{:error, reason}`: `:not_found` for a notebook or run the hub doesn't
  have, `:runs_full` when the notebook takes no more runs for now, or
  `:unavailable` when the hub didn't answer or the kept pages couldn't be
  read.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{Files, RecordsDownError}

  import Keyfleet.Notebooks.MemberRequest

  @job "Agent runs"
  # The most jobs a notebook holds on the hub, so one page lists them all.
  @jobs 100
  # A finished run has made its page, unless it was cancelled or skipped.
  @with_page ~w(succeeded failed timed_out)
  @finished ["cancelled" | @with_page]
  # How many of a job's newest runs are looked through for the last that
  # succeeded.
  @recent_runs 20
  # A listing asks after this many notebooks' runs at once.
  @lookups 4

  @doc """
  The fleet's 50 newest notebooks, newest first, as `subject`: each with its
  title, description and when it was added, as the Docs place lists them;
  its address (`Keyfleet.Notebooks.notebook_url/3`); and `subject`'s newest
  run there, or nil when they have started none.
  """
  def list(fleet_id, subject, project_id) do
    with {:ok, %{"items" => notebooks}} <-
           fleet_id
           |> request(subject, :get, "/api/v1/projects/#{segment(project_id)}/notebooks",
             params: [limit: 50]
           )
           |> answer(200),
         {:ok, runs} <- last_runs(fleet_id, subject, project_id, notebooks),
         {:ok, result_urls} <- result_urls(fleet_id, runs) do
      locks = Notebooks.locks(fleet_id)

      {:ok,
       Enum.zip_with(notebooks, runs, &listing(&1, &2, fleet_id, project_id, result_urls, locks))}
    end
  end

  @doc """
  Starts a run of `notebook_id`'s saved code as `subject`, recording what it
  runs from. The same `idempotency_key` starts one run however often it is
  sent.
  """
  def start(fleet_id, subject, project_id, notebook_id, idempotency_key) do
    notebook = notebook_path(project_id, notebook_id)

    with {:ok, %{"code" => code}} <-
           fleet_id |> request(subject, :get, notebook <> "/content") |> answer(200),
         {:ok, files} <- Files.list(fleet_id, subject, project_id, notebook_id, nil, nil),
         {:ok, job_id} <- job(fleet_id, subject, notebook),
         {:ok, run} <-
           fleet_id
           |> request(subject, :post, "#{notebook}/jobs/#{segment(job_id)}/runs",
             json: %{},
             headers: [{"idempotency-key", idempotency_key}]
           )
           |> answer(201) do
      source = record_source(fleet_id, notebook_id, run["run_id"], code, files)

      {:ok,
       notebook_id
       |> view(run, nil)
       |> Map.merge(%{source: source, code_current: nil, last_succeeded: nil})}
    end
  end

  @doc """
  Reads run `run_id` of `notebook_id` as `subject`, in whichever of the
  notebook's jobs it is, and once it has finished with a page, keeps that
  page and answers its address. A page already kept is answered as it is, so
  a finished run's page is fetched from the hub once.
  """
  def read(fleet_id, subject, project_id, notebook_id, run_id) do
    with {:ok, run_path, run} <- find(fleet_id, subject, project_id, notebook_id, run_id),
         {:ok, result_url} <- result_url(fleet_id, subject, notebook_id, run_id, run, run_path),
         {:ok, source} <- source(fleet_id, run_id),
         {:ok, current} <- code_current(fleet_id, subject, project_id, notebook_id, source, run),
         {:ok, last} <- last_succeeded(fleet_id, subject, notebook_id, run_path, run) do
      {:ok,
       notebook_id
       |> view(run, result_url)
       |> Map.merge(%{source: source, code_current: current, last_succeeded: last})}
    end
  end

  @doc """
  Run `run_id` of `notebook_id` as `subject`, in whichever of the notebook's
  jobs it is: `{:ok, run_path, run}`.
  """
  def find(fleet_id, subject, project_id, notebook_id, run_id) do
    notebook = notebook_path(project_id, notebook_id)

    with {:ok, %{"items" => jobs}} <-
           fleet_id
           |> request(subject, :get, notebook <> "/jobs", params: [limit: @jobs])
           |> answer(200),
         do: find_run(fleet_id, subject, notebook, own_first(jobs, subject), run_id)
  end

  # The agent's own jobs are asked first: most runs it reads are its own.
  defp own_first(jobs, subject), do: Enum.sort_by(jobs, &(&1["created_by"] != subject))

  # The agent's own job for its runs of the notebook, so only it stops them
  # (`Keyfleet.Notebooks.Makers`).
  defp job(fleet_id, subject, notebook) do
    with {:ok, %{"items" => jobs}} <-
           fleet_id
           |> request(subject, :get, notebook <> "/jobs", params: [limit: @jobs])
           |> answer(200) do
      case own_job(jobs, subject) do
        %{"id" => id} -> {:ok, id}
        nil -> create_job(fleet_id, subject, notebook)
      end
    end
  end

  defp own_job(jobs, subject),
    do: Enum.find(jobs, &(&1["name"] == @job and &1["created_by"] == subject))

  # Runs start only when asked, and several may wait at once.
  defp create_job(fleet_id, subject, notebook) do
    with {:ok, %{"id" => id}} <-
           fleet_id
           |> request(subject, :post, notebook <> "/jobs",
             json: %{name: @job, concurrency_policy: "allow"},
             headers: [{"idempotency-key", "keyfleet-agent-runs:" <> subject}]
           )
           |> answer(201) do
      {:ok, id}
    end
  end

  # Each notebook's newest run of the agent's, in the notebooks' order. A notebook the
  # hub doesn't answer for leaves the whole listing unanswered.
  defp last_runs(fleet_id, subject, project_id, notebooks) do
    answers =
      Task.async_stream(
        notebooks,
        &last_run(fleet_id, subject, notebook_path(project_id, &1["id"])),
        max_concurrency: @lookups,
        # Each asks the hub at most twice.
        timeout: 2 * Notebooks.config()[:hub_timeout_ms],
        on_timeout: :kill_task
      )

    with {:ok, runs} <- Enum.reduce_while(answers, {:ok, []}, &gather/2),
         do: {:ok, Enum.reverse(runs)}
  end

  defp gather({:ok, {:ok, run}}, {:ok, runs}), do: {:cont, {:ok, [run | runs]}}
  defp gather(_unanswered, _runs), do: {:halt, {:error, :unavailable}}

  defp last_run(fleet_id, subject, notebook) do
    with {:ok, %{"items" => jobs}} <-
           fleet_id
           |> request(subject, :get, notebook <> "/jobs", params: [limit: @jobs])
           |> answer(200) do
      case own_job(jobs, subject) do
        %{"id" => id} -> newest_run(fleet_id, subject, "#{notebook}/jobs/#{segment(id)}/runs")
        nil -> {:ok, nil}
      end
    end
  end

  # The hub lists a job's runs newest first.
  defp newest_run(fleet_id, subject, runs) do
    with {:ok, %{"items" => items}} <-
           fleet_id |> request(subject, :get, runs, params: [limit: 1]) |> answer(200),
         do: {:ok, List.first(items)}
  end

  # The listed runs' kept pages, read at once, by notebook and run. Of two
  # copies of one run's page, the newer is its saved result. A failed read is
  # saved with the site's errors (`Keyfleet.Notebooks.RecordsDownError`).
  defp result_urls(fleet_id, runs) do
    run_ids = for %{"run_id" => run_id} <- runs, do: run_id

    case Notebooks.saved_outputs(fleet_id, run_ids, actor: %System{}) do
      {:ok, kept} ->
        {:ok,
         kept
         |> Enum.sort_by(& &1.saved_at)
         |> Map.new(fn copy ->
           {{copy.notebook_id, copy.source_id},
            Notebooks.result_url(fleet_id, copy.notebook_id, copy.source_id, copy.saved_at)}
         end)}

      {:error, error} ->
        RecordsDownError.report(
          "The kept pages of #{fleet_id}'s notebook listing could not be read: " <>
            inspect(error.__struct__)
        )

        {:error, :unavailable}
    end
  end

  # A notebook with nothing kept of it is locked and nobody's scratchpad.
  defp listing(notebook, run, fleet_id, project_id, result_urls, locks) do
    lock = Map.get(locks, notebook["id"], %{locked: true, key: nil})

    %{
      notebook_id: notebook["id"],
      title: notebook["title"],
      description: notebook["description"],
      created_at: notebook["created_at"],
      locked: lock.locked,
      scratchpad_key: lock.key,
      notebook_url: Notebooks.notebook_url(fleet_id, project_id, notebook["id"]),
      last_run:
        if run do
          %{
            run_id: run["run_id"],
            status: run["status"],
            result_url: result_urls[{notebook["id"], run["run_id"]}]
          }
        end
    }
  end

  # What the run ran from, as recorded the moment it started; nil when the
  # record couldn't be written, which is saved with the site's errors.
  defp record_source(fleet_id, notebook_id, run_id, code, files) do
    entries = Enum.map(files.entries, &Map.take(&1, [:path, :kind, :size]))

    recorded =
      Notebooks.record_run_source(
        fleet_id,
        run_id,
        notebook_id,
        sha256(code),
        entries,
        files.cursor == nil,
        actor: %System{}
      )

    with {:ok, _recorded} <- recorded,
         {:ok, source} <- source(fleet_id, run_id) do
      source
    else
      {:error, :unavailable} ->
        nil

      {:error, error} ->
        RecordsDownError.report(
          "What #{fleet_id}'s run #{run_id} ran from could not be recorded: " <>
            inspect(error.__struct__)
        )

        nil
    end
  end

  defp source(fleet_id, run_id) do
    case Notebooks.run_source(fleet_id, run_id, actor: %System{}) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, source} ->
        {:ok,
         %{
           started_at: source.started_at,
           code_sha256: source.code_sha256,
           files: source.files,
           files_complete: source.files_complete
         }}

      {:error, error} ->
        RecordsDownError.report(
          "What #{fleet_id}'s run #{run_id} ran from could not be read: " <>
            inspect(error.__struct__)
        )

        {:error, :unavailable}
    end
  end

  # Whether a finished run's notebook still holds the code it ran from.
  defp code_current(fleet_id, subject, project_id, notebook_id, %{code_sha256: ran}, %{
         "status" => status
       })
       when status in @finished do
    with {:ok, %{"code" => code}} <-
           fleet_id
           |> request(subject, :get, notebook_path(project_id, notebook_id) <> "/content")
           |> answer(200),
         do: {:ok, sha256(code) == ran}
  end

  defp code_current(_fleet_id, _subject, _project_id, _notebook_id, _source, _run),
    do: {:ok, nil}

  # The newest run of the same job that succeeded, beside a run that hasn't:
  # its id and its saved result's address once Keyfleet keeps it.
  defp last_succeeded(_fleet_id, _subject, _notebook_id, _run_path, %{"status" => "succeeded"}),
    do: {:ok, nil}

  defp last_succeeded(fleet_id, subject, notebook_id, run_path, _run) do
    with {:ok, %{"items" => runs}} <-
           fleet_id
           |> request(subject, :get, Path.dirname(run_path), params: [limit: @recent_runs])
           |> answer(200) do
      runs |> Enum.find(&(&1["status"] == "succeeded")) |> succeeded(fleet_id, notebook_id)
    end
  end

  defp succeeded(nil, _fleet_id, _notebook_id), do: {:ok, nil}

  defp succeeded(%{"run_id" => run_id}, fleet_id, notebook_id) do
    with {:ok, kept} <- result_urls(fleet_id, [%{"run_id" => run_id}]),
         do: {:ok, %{run_id: run_id, result_url: kept[{notebook_id, run_id}]}}
  end

  defp sha256(code), do: :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)

  # Each job is asked in turn until one has the run.
  defp find_run(fleet_id, subject, notebook, jobs, run_id) do
    Enum.reduce_while(jobs, {:error, :not_found}, fn %{"id" => job_id}, not_found ->
      path = "#{notebook}/jobs/#{segment(job_id)}/runs/#{segment(run_id)}"

      case fleet_id |> request(subject, :get, path) |> answer(200) do
        {:ok, run} -> {:halt, {:ok, path, run}}
        {:error, :not_found} -> {:cont, not_found}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A finished run's kept page, kept now if it isn't yet; nil while the run
  # has no page.
  defp result_url(fleet_id, subject, notebook_id, run_id, %{"status" => status}, run_path)
       when status in @with_page do
    with {:ok, kept} <- result_urls(fleet_id, [%{"run_id" => run_id}]) do
      {:ok,
       kept[{notebook_id, run_id}] ||
         keep_page(fleet_id, subject, notebook_id, run_id, run_path <> "/html")}
    end
  end

  defp result_url(_fleet_id, _subject, _notebook_id, _run_id, _run, _run_path), do: {:ok, nil}

  # The run's page, read whole up to `saved_page_max_bytes` and kept under its
  # address, which is the answer; nil when there is no page to keep yet.
  defp keep_page(fleet_id, subject, notebook_id, run_id, path) do
    cap = Notebooks.config()[:saved_page_max_bytes]

    with {:ok, %Req.Response{status: 200, body: page} = response} when is_binary(page) <-
           request(fleet_id, subject, :get, path, into: &read_capped(&1, &2, cap)),
         [] <- Req.Response.get_header(response, "content-encoding"),
         [^run_id] <- Req.Response.get_header(response, "x-marimohub-run-id"),
         [captured_at] <- Req.Response.get_header(response, "x-marimohub-captured-at"),
         {:ok, saved_at} <- Notebooks.saved_at(captured_at),
         {:ok, _kept} <-
           Notebooks.keep_saved_output(fleet_id, notebook_id, run_id, saved_at, page,
             actor: %System{}
           ) do
      Notebooks.result_url(fleet_id, notebook_id, run_id, saved_at)
    else
      _no_page -> nil
    end
  end

  defp read_capped({:data, data}, {request, response}, cap) do
    if byte_size(response.body) + byte_size(data) > cap,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: response.body <> data}}}
  end

  defp view(notebook_id, run, result_url) do
    %{
      notebook_id: notebook_id,
      run_id: run["run_id"],
      status: run["status"],
      result_url: result_url
    }
  end

  defp answer({:ok, %Req.Response{status: status, body: %{"data" => data}}}, status),
    do: {:ok, data}

  defp answer({:ok, %Req.Response{status: 404}}, _status), do: {:error, :not_found}
  defp answer({:ok, %Req.Response{status: 429}}, _status), do: {:error, :runs_full}
  defp answer(_response, _status), do: {:error, :unavailable}
end
