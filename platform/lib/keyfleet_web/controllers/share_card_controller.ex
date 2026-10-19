defmodule KeyfleetWeb.ShareCardController do
  @moduledoc """
  Serves each fleet's share picture (`KeyfleetWeb.ShareCard`) at
  `/share/<fleet id>.png`, kept by readers for five minutes. A page names it
  with a version of its figures, so a new version is a new address; the
  picture served is always the one of the figures held now. Before they are
  first read, or when its latest Key's card can't be read, the answer is 503,
  asked again in a minute.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.ShareCard

  def show(conn, %{"file" => file}) do
    fleet_id = String.replace_suffix(file, ".png", "")

    if fleet_id <> ".png" == file and fleet_id in ShareCard.fleets(),
      do: picture(conn, fleet_id),
      else: send_resp(conn, 404, "")
  end

  defp picture(conn, fleet_id) do
    case ShareCard.png(fleet_id) do
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
