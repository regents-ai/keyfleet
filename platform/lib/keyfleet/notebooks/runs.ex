defmodule Keyfleet.Notebooks.Runs do
  @moduledoc """
  Background runs of a fleet's notebooks that an agent starts and reads
  through its own signed requests to this site
  (`KeyfleetWeb.AgentNotebookController`), so it never signs a request for
  the notebook host itself.

  The hub is asked as the agent (`Keyfleet.Notebooks.Pass`), so a run is the
  agent's, in the notebook's job kept for agents' runs, "Agent runs", made the
  first time an agent starts a run there. A run works through the notebook's
  saved code, top to bottom, in a fresh sandbox, and never changes the
  notebook.

  Reading a finished run keeps its page and answers the saved result's
  address (`Keyfleet.Notebooks.result_url/4`), as reading that page on the
  notebook host does (`KeyfleetWeb.Plugs.NotebookGateway`): an address is
  never handed out for a page Keyfleet hasn't kept.

  Each answer is `{:ok, run}`, with the notebook, the run and its status and,
  once its page is kept, `result_url`; or `{:error, reason}`: `:not_found` for
  a notebook or run the hub doesn't have, `:runs_full` when the notebook takes
  no more runs for now, or `:unavailable` when the hub didn't answer.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.Pass

  @job "Agent runs"
  # A finished run has made its page, unless it was cancelled or skipped.
  @with_page ~w(succeeded failed timed_out)

  @doc """
  Starts a run of `notebook_id`'s saved code as `subject`. The same
  `idempotency_key` starts one run however often it is sent.
  """
  def start(fleet_id, subject, project_id, notebook_id, idempotency_key) do
    notebook = notebook_path(project_id, notebook_id)

    with {:ok, job_id} <- job(fleet_id, subject, notebook),
         {:ok, run} <-
           fleet_id
           |> request(subject, :post, "#{notebook}/jobs/#{segment(job_id)}/runs",
             json: %{},
             headers: [{"idempotency-key", idempotency_key}]
           )
           |> answer(201) do
      {:ok, view(notebook_id, run, nil)}
    end
  end

  @doc """
  Reads run `run_id` of `notebook_id` as `subject`, in whichever of the
  notebook's jobs it is, and once it has finished with a page, keeps that
  page and answers its address.
  """
  def read(fleet_id, subject, project_id, notebook_id, run_id) do
    notebook = notebook_path(project_id, notebook_id)

    with {:ok, %{"items" => jobs}} <-
           fleet_id |> request(subject, :get, notebook <> "/jobs") |> answer(200),
         {:ok, run_path, run} <- find_run(fleet_id, subject, notebook, jobs, run_id) do
      result_url =
        if run["status"] in @with_page,
          do: keep_page(fleet_id, subject, notebook_id, run_id, run_path <> "/html")

      {:ok, view(notebook_id, run, result_url)}
    end
  end

  # The notebook's job for agents' runs. Two agents making it at once make
  # two, and every later run uses the first.
  defp job(fleet_id, subject, notebook) do
    with {:ok, %{"items" => jobs}} <-
           fleet_id |> request(subject, :get, notebook <> "/jobs") |> answer(200) do
      case Enum.find(jobs, &(&1["name"] == @job)) do
        %{"id" => id} -> {:ok, id}
        nil -> create_job(fleet_id, subject, notebook)
      end
    end
  end

  # Runs start only when asked, and several may wait at once.
  defp create_job(fleet_id, subject, notebook) do
    with {:ok, %{"id" => id}} <-
           fleet_id
           |> request(subject, :post, notebook <> "/jobs",
             json: %{name: @job, concurrency_policy: "allow"},
             headers: [{"idempotency-key", "keyfleet-agent-runs"}]
           )
           |> answer(201) do
      {:ok, id}
    end
  end

  # A notebook has at most a handful of jobs, so each is asked in turn.
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

  defp notebook_path(project_id, notebook_id),
    do: "/api/v1/projects/#{segment(project_id)}/notebooks/#{segment(notebook_id)}"

  defp request(fleet_id, subject, method, path, options \\ []) do
    {:ok, address} = Notebooks.hub_address(fleet_id)
    {headers, options} = Keyword.pop(options, :headers, [])

    Req.request(
      [
        method: method,
        base_url: address,
        url: path,
        headers: [{"x-keyfleet-assertion", Pass.mint(fleet_id, subject)} | headers],
        retry: false,
        redirect: false,
        receive_timeout: Notebooks.config()[:hub_timeout_ms]
      ] ++ options
    )
  end

  defp answer({:ok, %Req.Response{status: status, body: %{"data" => data}}}, status),
    do: {:ok, data}

  defp answer({:ok, %Req.Response{status: 404}}, _status), do: {:error, :not_found}
  defp answer({:ok, %Req.Response{status: 429}}, _status), do: {:error, :runs_full}
  defp answer(_response, _status), do: {:error, :unavailable}

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
