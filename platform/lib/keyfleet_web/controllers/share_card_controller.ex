defmodule KeyfleetWeb.ShareCardController do
  @moduledoc """
  Serves each fleet's share picture (`KeyfleetWeb.ShareCard`) at
  `/share/<fleet id>.png`, and each of its projects' at
  `/share/projects/<fleet id>/<project name>.png`, kept by readers for five
  minutes. A page names one with a version of what it shows, so a new version
  is a new address; the picture served is always the one of what is held
  now. Before that is first read, or when the card it shows can't be read,
  the answer is 503, asked again in a minute. A project its fleet's last read
  did not find is 503 too, since one just started arrives with the next.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.ShareCard

  def show(conn, %{"file" => file}) do
    fleet_id = String.replace_suffix(file, ".png", "")

    if fleet_id <> ".png" == file and fleet_id in ShareCard.fleets(),
      do: picture(conn, ShareCard.png(fleet_id)),
      else: send_resp(conn, 404, "")
  end

  def project(conn, %{"fleet_id" => fleet_id, "file" => file}) do
    name = String.replace_suffix(file, ".png", "")

    if name <> ".png" == file and fleet_id in ShareCard.fleets(),
      do: picture(conn, ShareCard.project_png(fleet_id, name)),
      else: send_resp(conn, 404, "")
  end

  defp picture(conn, drawn) do
    case drawn do
      {:ok, png} ->
        conn
        |> put_resp_content_type("image/png", nil)
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, png)

      {:error, _reason} ->
        conn |> put_resp_header("retry-after", "60") |> send_resp(503, "")
    end
  end
end
