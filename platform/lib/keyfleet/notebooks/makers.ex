defmodule Keyfleet.Notebooks.Makers do
  @moduledoc """
  Who made each thing in a fleet's notebooks. Sean, 21 Oct 2026: members
  open, copy and run each other's work, and only whoever made a thing
  removes, changes or stops it.

  The hub keeps who made most things, and is asked as the member checking
  (`Keyfleet.Notebooks.MemberRequest`): a notebook's author, who started a
  session, who made a job, who started a run. A saved result's maker is its
  notebook's author for a version's page and whoever started the run for a
  run's page. Who added a workspace file or folder is kept here
  (`Keyfleet.Notebooks.FileMaker`); a path with no maker kept is the
  notebook's author's.

  Each check is `:ok` for the maker, or `{:error, reason}`: `:not_maker`,
  `:not_found` when the hub doesn't have the thing, or `:unavailable` when
  the hub or the kept makers can't be read.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{FileMaker, RecordsDownError, Runs}

  import Keyfleet.Notebooks.MemberRequest

  # The hub lists at most this many workspace entries a page.
  @page 500

  @doc "Whether `subject` made the notebook."
  def notebook(fleet_id, subject, project_id, notebook_id) do
    fleet_id
    |> request(subject, :get, notebook_path(project_id, notebook_id))
    |> made_by(subject, &get_in(&1, ["meta", "author"]))
  end

  @doc "Whether `subject` started the session."
  def session(fleet_id, subject, project_id, notebook_id, session_id) do
    path = "#{notebook_path(project_id, notebook_id)}/sessions/#{segment(session_id)}"
    fleet_id |> request(subject, :get, path) |> made_by(subject, & &1["user_id"])
  end

  @doc "Whether `subject` made the job."
  def job(fleet_id, subject, project_id, notebook_id, job_id) do
    path = "#{notebook_path(project_id, notebook_id)}/jobs/#{segment(job_id)}"
    fleet_id |> request(subject, :get, path) |> made_by(subject, & &1["created_by"])
  end

  @doc "Whether `subject` started the run."
  def run(fleet_id, subject, project_id, notebook_id, job_id, run_id) do
    path =
      "#{notebook_path(project_id, notebook_id)}/jobs/#{segment(job_id)}/runs/#{segment(run_id)}"

    fleet_id |> request(subject, :get, path) |> made_by(subject, & &1["triggered_by"])
  end

  @doc """
  Whether `subject` made the saved result of `source_id`: a version's
  (`ver_…`) is its notebook's author's, a run's (`run_…`) whoever started it.
  """
  def result(fleet_id, subject, notebook_id, source_id) do
    with {:ok, project_id} when is_binary(project_id) <- Notebooks.project_id(fleet_id) do
      case source_id do
        "run_" <> _ -> result_run(fleet_id, subject, project_id, notebook_id, source_id)
        _version -> notebook(fleet_id, subject, project_id, notebook_id)
      end
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _error} -> {:error, :unavailable}
    end
  end

  defp result_run(fleet_id, subject, project_id, notebook_id, run_id) do
    with {:ok, _path, run} <- Runs.find(fleet_id, subject, project_id, notebook_id, run_id) do
      if run["triggered_by"] == subject, do: :ok, else: {:error, :not_maker}
    end
  end

  defp made_by({:ok, %Req.Response{status: 200, body: %{"data" => data}}}, subject, maker),
    do: if(maker.(data) == subject, do: :ok, else: {:error, :not_maker})

  defp made_by({:ok, %Req.Response{status: 404}}, _subject, _maker), do: {:error, :not_found}
  defp made_by(_answer, _subject, _maker), do: {:error, :unavailable}

  ## Workspace files

  @doc """
  The path the hub keeps a workspace file under, for the `path` a request
  names: without its one leading `/`.
  """
  def file_key("//" <> _ = path), do: path
  def file_key(path), do: String.replace_prefix(path, "/", "")

  @doc "The path the hub keeps a folder under: without one leading and one trailing `/`."
  def folder_key(path), do: path |> file_key() |> String.replace_suffix("/", "")

  @doc "Whether `subject` may write over the file at `key`: its maker may."
  def overwrite(fleet_id, subject, project_id, notebook_id, key) do
    with {:ok, makers} <- kept_makers(fleet_id, notebook_id, key) do
      case makers do
        %{^key => ^subject} -> :ok
        %{^key => _other} -> {:error, :not_maker}
        _none -> notebook(fleet_id, subject, project_id, notebook_id)
      end
    end
  end

  @doc """
  Whether `subject` may remove `key` and everything under it: they made each
  file under it, and each folder with nothing in it, or the file itself.
  """
  def removal(fleet_id, subject, project_id, notebook_id, key) do
    with {:ok, leaves} <- leaves(fleet_id, subject, project_id, notebook_id, key),
         {:ok, makers} <- kept_makers(fleet_id, notebook_id, key) do
      cond do
        Enum.any?(leaves, &(Map.get(makers, &1, subject) != subject)) -> {:error, :not_maker}
        Enum.all?(leaves, &Map.has_key?(makers, &1)) -> :ok
        true -> notebook(fleet_id, subject, project_id, notebook_id)
      end
    end
  end

  @doc "Keeps `subject` as the maker of the file or folder at `key`."
  def record(fleet_id, notebook_id, key, subject) do
    case Notebooks.record_file_maker(fleet_id, notebook_id, key, subject, actor: %System{}) do
      {:ok, _maker} -> :ok
      {:error, error} -> down("kept", fleet_id, notebook_id, error)
    end
  end

  @doc "Forgets the makers of `key` and everything under it, once they are removed."
  def forget(fleet_id, notebook_id, key) do
    FileMaker
    |> Ash.Query.for_read(
      :at_or_under,
      %{fleet_id: fleet_id, notebook_id: notebook_id, path: key},
      actor: %System{}
    )
    |> Ash.bulk_destroy(:forget, %{}, actor: %System{}, strategy: :atomic, notify?: false)
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> down("forgotten", fleet_id, notebook_id, errors)
    end
  end

  defp kept_makers(fleet_id, notebook_id, key) do
    case Notebooks.file_makers_at_or_under(fleet_id, notebook_id, key, actor: %System{}) do
      {:ok, rows} -> {:ok, Map.new(rows, &{&1.path, &1.maker})}
      {:error, error} -> down("read", fleet_id, notebook_id, error)
    end
  end

  defp down(what, fleet_id, notebook_id, error) do
    RecordsDownError.report(
      "Who made the files of notebook #{notebook_id} in #{fleet_id} could not be #{what}: " <>
        inspect(error)
    )

    {:error, :unavailable}
  end

  # Each file under `key`, and each folder there with nothing in it; `key`
  # itself when nothing is under it (a file, or an empty folder).
  defp leaves(fleet_id, subject, project_id, notebook_id, key) do
    case under(fleet_id, subject, project_id, notebook_id, key) do
      {:ok, []} -> {:ok, [key]}
      found -> found
    end
  end

  defp under(fleet_id, subject, project_id, notebook_id, folder) do
    with {:ok, items} <- entries(fleet_id, subject, project_id, notebook_id, folder, nil, []) do
      Enum.reduce_while(items, {:ok, []}, fn
        %{"kind" => "directory", "path" => path}, {:ok, leaves} ->
          case leaves(fleet_id, subject, project_id, notebook_id, path) do
            {:ok, found} -> {:cont, {:ok, found ++ leaves}}
            error -> {:halt, error}
          end

        %{"path" => path}, {:ok, leaves} ->
          {:cont, {:ok, [path | leaves]}}
      end)
    end
  end

  defp entries(fleet_id, subject, project_id, notebook_id, folder, cursor, items) do
    params = [path: folder, limit: @page] ++ if(cursor, do: [cursor: cursor], else: [])

    case request(
           fleet_id,
           subject,
           :get,
           notebook_path(project_id, notebook_id) <> "/workspace/entries",
           params: params
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"items" => page} = data}}} ->
        case data["cursor"] do
          nil -> {:ok, page ++ items}
          next -> entries(fleet_id, subject, project_id, notebook_id, folder, next, page ++ items)
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      _answer ->
        {:error, :unavailable}
    end
  end
end
