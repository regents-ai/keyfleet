defmodule KeyfleetWeb.DirectoryController do
  @moduledoc """
  The open fleet directory, for anyone to compare the fleets without signing
  in: `/fleets.md` and `/fleets/<id>.md` as Markdown, `/api/v1/fleets` and
  `/api/v1/fleets/<id>` as JSON, all read from `Keyfleet.Directory`.

  Answers may be kept for 30 seconds; nothing is kept on the server. When a
  count the directory gives can't be read, it answers 503 and says so.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Directory, Fleets}
  alias KeyfleetWeb.{DirectoryJSON, DirectoryMD, ErrorMD, Refusal}

  @unavailable "The fleet directory can't be read right now. Try again in a moment."

  def index_md(conn, _params) do
    case Directory.list() do
      {:ok, fleets} -> markdown(conn, DirectoryMD.index(%{fleets: fleets, generated_at: now()}))
      {:error, _failure} -> unavailable_md(conn)
    end
  end

  # A fleet's Markdown sits at its id with `.md` after it. Anything else here
  # is not a page of the directory.
  def show_md(conn, %{"file" => file}) do
    with {:ok, fleet_id} <- fleet_file(file),
         {:ok, fleet} <- Directory.fleet(fleet_id) do
      markdown(conn, DirectoryMD.show(%{fleet: fleet, generated_at: now()}))
    else
      {:error, _failure} ->
        unavailable_md(conn)

      _not_a_fleet ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(404, ErrorMD.render("404.md", %{}))
    end
  end

  def index_json(conn, _params) do
    case Directory.list() do
      {:ok, fleets} ->
        conn |> cached() |> json(DirectoryJSON.index(%{fleets: fleets, generated_at: now()}))

      {:error, _failure} ->
        unavailable_json(conn)
    end
  end

  def show_json(conn, %{"fleet_id" => fleet_id}) do
    case Directory.fleet(fleet_id) do
      {:ok, fleet} ->
        conn |> cached() |> json(DirectoryJSON.show(%{fleet: fleet, generated_at: now()}))

      :unknown ->
        Refusal.json(conn, 404, "fleet_unknown")

      {:error, _failure} ->
        unavailable_json(conn)
    end
  end

  defp unavailable_md(conn) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(503, @unavailable <> "\n")
  end

  defp unavailable_json(conn), do: Refusal.json(conn, 503, "directory_unavailable")

  defp fleet_file(file) do
    with fleet_id when fleet_id != file <- String.replace_suffix(file, ".md", ""),
         true <- fleet_id in Fleets.catalog_ids() do
      {:ok, fleet_id}
    end
  end

  defp markdown(conn, body) do
    conn
    |> cached()
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, body)
  end

  defp cached(conn), do: put_resp_header(conn, "cache-control", "public, max-age=30")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
