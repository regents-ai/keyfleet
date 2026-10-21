defmodule Keyfleet.Notebooks.Files do
  @moduledoc """
  A fleet's notebooks and their files, that an agent creates, lists, reads
  and writes through its own signed requests to this site
  (`KeyfleetWeb.AgentNotebookController`), so it never signs a request for
  the notebook host itself. The hub is asked as the agent
  (`Keyfleet.Notebooks.MemberRequest`), so each notebook and each change is
  the agent's.

  A notebook's files sit beside its code, `notebook.py`, which its runs and
  sessions see. Writing `notebook.py` or `pyproject.toml` saves a new version
  of the notebook. Adding a file never replaces one, so many writers can each
  add files of their own to one notebook without losing any, and only a
  file's maker writes over it.

  Each answer is `{:ok, answer}` or `{:error, reason}`: `:file_not_found` for a
  notebook or file the hub doesn't have; `:conflict` when a file added is
  there already, or the notebook is open for editing or saving another change;
  `:not_maker` for writing over another member's file; `:refused` for a path
  or file the hub doesn't take;
  `:files_full` when the notebook holds as much as it takes; `:too_large` or
  `:not_text` for a file this site doesn't read out; or `:unavailable` when
  the hub didn't answer.
  """

  import Keyfleet.Notebooks.MemberRequest

  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.Makers

  # A file read out here is text, at most this many bytes.
  @read_max_bytes 1024 * 1024
  # A listing names at most this many entries a page.
  @page 200

  @doc """
  Makes a notebook titled `title` with `code` as `subject`, answering its id,
  title and address (`Keyfleet.Notebooks.notebook_url/3`). The same
  `idempotency_key` makes one notebook however often it is sent.
  """
  def create(fleet_id, subject, project_id, notebook, idempotency_key) do
    fleet_id
    |> request(subject, :post, "/api/v1/projects/#{segment(project_id)}/notebooks",
      json: Map.put_new(notebook, "description", ""),
      headers: [{"idempotency-key", idempotency_key}]
    )
    |> answer(201)
    |> case do
      {:ok, %{"id" => id, "title" => title}} ->
        {:ok,
         %{
           notebook_id: id,
           title: title,
           notebook_url: Notebooks.notebook_url(fleet_id, project_id, id)
         }}

      error ->
        error
    end
  end

  @doc """
  The entries of the folder `path` in `notebook_id`, as `subject`: a page
  of them, and the `cursor` that names the next page, or nil after the last.
  """
  def list(fleet_id, subject, project_id, notebook_id, path, cursor) do
    params = [path: path, cursor: cursor, limit: @page] |> Enum.reject(&is_nil(elem(&1, 1)))

    with {:ok, %{"items" => items} = page} <-
           fleet_id
           |> request(
             subject,
             :get,
             notebook_path(project_id, notebook_id) <> "/workspace/entries",
             params: params
           )
           |> answer(200) do
      {:ok, %{entries: Enum.map(items, &entry/1), cursor: page["cursor"]}}
    end
  end

  @doc "The text of the file at `path` in `notebook_id`, as `subject`."
  def read(fleet_id, subject, project_id, notebook_id, path) do
    case request(
           fleet_id,
           subject,
           :get,
           notebook_path(project_id, notebook_id) <> "/workspace/files",
           params: [path: path],
           compressed: false,
           into: &read_capped/2
         ) do
      {:ok, %Req.Response{status: 200, body: :too_large}} ->
        {:error, :too_large}

      {:ok, %Req.Response{status: 200, body: content}} when is_binary(content) ->
        if String.valid?(content),
          do: {:ok, %{path: path, content: content}},
          else: {:error, :not_text}

      response ->
        answer(response, 200)
    end
  end

  @doc """
  Writes `content` to the file at `path` in `notebook_id`, as `subject`,
  making its folders as needed: `:add` makes a new file, kept as
  `subject`'s, and leaves one already there as it is, answering `:conflict`;
  `:write` replaces a file `subject` made, answering `:not_maker` for anyone
  else's (`Keyfleet.Notebooks.Makers`). A file added whose maker can't be
  kept is removed again, so it never stays as the notebook maker's.
  """
  def write(fleet_id, subject, project_id, notebook_id, path, content, :add) do
    with {:ok, key} <- file_key(path),
         {:ok, item} <- put(fleet_id, subject, project_id, notebook_id, path, content, true),
         :ok <- Makers.record_added(fleet_id, subject, project_id, notebook_id, key),
         do: {:ok, item}
  end

  def write(fleet_id, subject, project_id, notebook_id, path, content, :write) do
    with {:ok, key} <- file_key(path) do
      case Makers.overwrite(fleet_id, subject, project_id, notebook_id, key) do
        :ok -> put(fleet_id, subject, project_id, notebook_id, path, content, false)
        {:error, :not_found} -> {:error, :file_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp file_key(path) do
    with :error <- Makers.file_key(path), do: {:error, :refused}
  end

  defp put(fleet_id, subject, project_id, notebook_id, path, content, create) do
    with {:ok, item} <-
           fleet_id
           |> request(subject, :put, notebook_path(project_id, notebook_id) <> "/workspace/files",
             params: [path: path, create: create],
             headers: [{"content-type", "application/octet-stream"}],
             body: content
           )
           |> answer(200),
         do: {:ok, entry(item)}
  end

  defp entry(item) do
    %{
      path: item["path"],
      kind: item["kind"],
      size: item["size"],
      modified_at: item["modified_at"]
    }
  end

  defp read_capped({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) > @read_max_bytes,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: response.body <> data}}}
  end

  defp answer({:ok, %Req.Response{status: status, body: %{"data" => data}}}, status),
    do: {:ok, data}

  defp answer({:ok, %Req.Response{status: 404}}, _status), do: {:error, :file_not_found}
  defp answer({:ok, %Req.Response{status: 409}}, _status), do: {:error, :conflict}

  defp answer({:ok, %Req.Response{status: status}}, _status) when status in [400, 403, 422],
    do: {:error, :refused}

  defp answer({:ok, %Req.Response{status: status}}, _status) when status in [413, 429],
    do: {:error, :files_full}

  defp answer(_response, _status), do: {:error, :unavailable}
end
