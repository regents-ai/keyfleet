defmodule KeyfleetWeb.DirectoryController do
  @moduledoc """
  The open fleet directory, for anyone to compare the fleets without signing
  in: `/fleets.md` and `/fleets/<id>.md` as Markdown, `/api/v1/fleets` and
  `/api/v1/fleets/<id>` as JSON, all read from `Keyfleet.Directory`.

  Answers may be kept for 30 seconds; nothing is kept on the server. When a
  count the directory gives can't be read, it answers 503 and says so.

  A browser that opens `/fleets/<id>` or `/fleets/<id>/rooms` is sent to the
  fleet's page or its General room; any other request there is sent to the
  fleet's Markdown. An unknown fleet is the site's not-found page for a browser
  and 404 `fleet_unknown`, as the API answers it, for anything else.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Directory, Fleets}
  alias KeyfleetWeb.{DirectoryJSON, DirectoryMD, ErrorHTML, Refusal}

  @unavailable "The fleet directory can't be read right now. Try again in a moment."

  def index_md(conn, _params) do
    case Directory.list() do
      {:ok, fleets} -> markdown(conn, DirectoryMD.index(%{fleets: fleets, generated_at: now()}))
      {:error, _failure} -> unavailable_md(conn)
    end
  end

  # A fleet's Markdown sits at its id with `.md` after it; its id alone opens
  # the fleet.
  def show_md(conn, %{"file" => file}) do
    case String.split(file, ".md", parts: 2) do
      [fleet_id, ""] -> fleet_md(conn, fleet_id)
      _fleet_id -> open_fleet(conn, file, ~p"/app/fleets/#{file}")
    end
  end

  def rooms(conn, %{"fleet_id" => fleet_id}),
    do: open_fleet(conn, fleet_id, ~p"/app/fleets/#{fleet_id}/rooms/general")

  defp fleet_md(conn, fleet_id) do
    case Directory.fleet(fleet_id) do
      {:ok, fleet} -> markdown(conn, DirectoryMD.show(%{fleet: fleet, generated_at: now()}))
      :unknown -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, _failure} -> unavailable_md(conn)
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

  # A browser opens the fleet's page; anything else, an agent, reads the
  # fleet's Markdown.
  defp open_fleet(conn, fleet_id, page) do
    case {fleet_id in Fleets.catalog_ids(), browser?(conn)} do
      {true, true} -> redirect(conn, to: page)
      {true, false} -> redirect(conn, to: ~p"/fleets/#{fleet_id <> ".md"}")
      {false, true} -> not_found_html(conn)
      {false, false} -> Refusal.json(conn, 404, "fleet_unknown")
    end
  end

  defp not_found_html(conn) do
    conn
    |> put_status(404)
    |> put_format("html")
    |> put_view(html: ErrorHTML)
    |> render(:"404")
  end

  defp unavailable_md(conn) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(503, @unavailable <> "\n")
  end

  defp unavailable_json(conn), do: Refusal.json(conn, 503, "directory_unavailable")

  defp markdown(conn, body) do
    conn
    |> cached()
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, body)
  end

  defp cached(conn), do: put_resp_header(conn, "cache-control", "public, max-age=30")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
