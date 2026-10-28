defmodule Keyfleet.Code.NodeClient do
  @moduledoc """
  What this site asks of the code store outside git itself, under a pass that
  opens only the one repository (`Keyfleet.Code.Pass`). Every call is
  made once: the job that makes it retries the whole job, and a page reads
  afresh when it is opened again.
  """

  alias Keyfleet.Code
  alias Keyfleet.Code.Pass

  @doc """
  Makes a project's private repository, or finds the one already made:
  `{:ok, owner}`, the owner the store keeps it under, or `{:error, reason}`.
  """
  def create_repository(repository) do
    request(
      Pass.create(repository),
      [method: :post, url: "/api/v1/repos", json: %{name: repository, is_public: false}],
      Code.config()[:node_timeout_ms]
    )
    |> case do
      {:ok, %Req.Response{status: status, body: %{"owner_did" => owner}}}
      when status in [200, 201] and is_binary(owner) ->
        {:ok, owner}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:code_store_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Deletes the repository from the store for good, with its history:
  `:ok`, also when it is already gone, or `{:error, reason}`.
  """
  def delete_repository(repository, owner) do
    url = Path.join(["/api/v1/repos", segment(owner), segment(repository)])

    case request(
           Pass.delete(repository),
           [method: :delete, url: url],
           Code.config()[:node_timeout_ms]
         ) do
      {:ok, %Req.Response{status: 204}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:code_store_status, status}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  What the folder `path` holds on the default branch now, or at the commit
  `at` (a full hash), `""` for the top:
  `{:ok, entries}`, each with `type` (`"blob"` for a file, `"tree"` for a
  folder), `name` and, for a file, `size`; or `{:error, reason}`.
  A folder that isn't there, or a file, holds nothing.
  """
  def tree(repository, owner, path, at \\ nil) do
    url = Path.join(["/api/v1/repos", segment(owner), segment(repository), "tree", encode(path)])

    case request(
           Pass.read(repository),
           [method: :get, url: url, params: at(at)],
           Code.config()[:page_timeout_ms]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"entries" => entries}}} when is_list(entries) ->
        {:ok, entries}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:code_store_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The file at `path` on the default branch now, or at the commit `at`:
  `{:ok, bytes}`, `{:ok, :too_large}` past `file_max_bytes`, `:not_found`,
  or `{:error, reason}`.
  """
  def blob(repository, owner, path, at \\ nil) do
    url = Path.join(["/api/v1/repos", segment(owner), segment(repository), "blob", encode(path)])
    cap = Code.config()[:file_max_bytes]

    case request(
           Pass.read(repository),
           [
             method: :get,
             url: url,
             params: at(at),
             decode_body: false,
             into: &read_capped(&1, &2, cap)
           ],
           Code.config()[:page_timeout_ms]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> :not_found
      {:ok, %Req.Response{status: status}} -> {:error, {:code_store_status, status}}
      {:error, error} -> {:error, error}
    end
  end

  # The store reads the default branch unless `ref` names a commit.
  defp at(nil), do: []
  defp at(hash), do: [ref: hash]

  # A page waits `page_timeout_ms` at most for what it shows; a job waits
  # `node_timeout_ms`.
  defp request(pass, options, timeout) do
    Req.request(
      [
        base_url: Code.config()[:node],
        auth: {:bearer, pass},
        retry: false,
        redirect: false,
        # The store's private Flycast address has only an IPv6 record.
        connect_options: [transport_opts: [inet6: true], timeout: timeout],
        receive_timeout: timeout
      ] ++ options ++ Code.config()[:req_options]
    )
  end

  defp read_capped({:data, data}, {request, response}, cap) do
    if byte_size(response.body) + byte_size(data) > cap,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: response.body <> data}}}
  end

  defp encode(path), do: path |> String.split("/", trim: true) |> Enum.map_join("/", &segment/1)

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
