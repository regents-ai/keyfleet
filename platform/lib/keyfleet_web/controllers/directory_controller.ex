defmodule KeyfleetWeb.DirectoryController do
  @moduledoc """
  The open fleet directory, for anyone to compare the fleets without signing
  in: `/fleets.md` and `/fleets/<id>.md` as Markdown, `/api/v1/fleets` and
  `/api/v1/fleets/<id>` as JSON, all read from `Keyfleet.Directory`.

  Answers may be kept for 30 seconds; nothing is kept on the server. When a
  count the directory gives can't be read, it answers 503 and says so.

  A browser that opens `/fleets/<id>` or `/fleets/<id>/rooms` is sent to the
  fleet's page or its General room; one that opens anything else there gets the
  site's not-found page. Every other request gets what an agent always has.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Directory, Fleets}
  alias KeyfleetWeb.{DirectoryJSON, DirectoryMD, ErrorHTML, ErrorMD, NotFoundError, Refusal}

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
    if browser?(conn) and not String.ends_with?(file, ".md"),
      do: open_page(conn, file, ~p"/app/fleets/#{file}"),
      else: fleet_md(conn, file)
  end

  def rooms(conn, %{"fleet_id" => fleet_id}) do
    if browser?(conn),
      do: open_page(conn, fleet_id, ~p"/app/fleets/#{fleet_id}/rooms/general"),
      else: raise(NotFoundError)
  end

  defp fleet_md(conn, file) do
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

  # A request that prefers HTML to Markdown; one asking for anything, as most
  # programs do, prefers Markdown here.
  defp browser?(conn) do
    conn
    |> get_req_header("accept")
    |> RegentAgentAccess.negotiate([{"md", "text", "markdown"}, {"html", "text", "html"}]) ==
      "html"
  end

  defp open_page(conn, fleet_id, path) do
    if fleet_id in Fleets.catalog_ids() do
      redirect(conn, to: path)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(404, Phoenix.HTML.Safe.to_iodata(ErrorHTML.render("404.html", %{conn: conn})))
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
