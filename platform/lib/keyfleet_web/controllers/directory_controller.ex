defmodule KeyfleetWeb.DirectoryController do
  @moduledoc """
  The open fleet directory, for anyone to compare the fleets without signing
  in: `/fleets.md` and `/fleets/<id>.md` as Markdown, `/api/v1/fleets` and
  `/api/v1/fleets/<id>` as JSON, all read from `Keyfleet.Directory`.

  Answers may be kept for 30 seconds; nothing is kept on the server.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Directory, Fleets}
  alias KeyfleetWeb.{DirectoryJSON, DirectoryMD, ErrorMD}

  def index_md(conn, _params),
    do: markdown(conn, DirectoryMD.index(%{fleets: Directory.list(), generated_at: now()}))

  # A fleet's Markdown sits at its id with `.md` after it. Anything else here
  # is not a page of the directory.
  def show_md(conn, %{"file" => file}) do
    with {:ok, fleet_id} <- fleet_file(file),
         {:ok, fleet} <- Directory.fleet(fleet_id) do
      markdown(conn, DirectoryMD.show(%{fleet: fleet, generated_at: now()}))
    else
      _not_a_fleet ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(404, ErrorMD.render("404.md", %{}))
    end
  end

  def index_json(conn, _params),
    do:
      conn
      |> cached()
      |> json(DirectoryJSON.index(%{fleets: Directory.list(), generated_at: now()}))

  def show_json(conn, %{"fleet_id" => fleet_id}) do
    case Directory.fleet(fleet_id) do
      {:ok, fleet} ->
        conn |> cached() |> json(DirectoryJSON.show(%{fleet: fleet, generated_at: now()}))

      :unknown ->
        conn |> put_status(404) |> json(%{error: "fleet_unknown"})
    end
  end

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
