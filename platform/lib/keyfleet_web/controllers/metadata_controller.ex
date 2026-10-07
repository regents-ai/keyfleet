defmodule KeyfleetWeb.MetadataController do
  @moduledoc """
  Serves each Key's ERC-721 metadata at the path the Key collection's
  `tokenURI` names, and the collection's own at its `contractURI`. A key still being revealed, or whose card is still being drawn, is
  cached for 30 seconds and a key with its card for an hour, so the card shows
  soon after it is drawn and a record corrected by hand soon after that.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Keys.Metadata

  def collection(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(Metadata.collection(url(~p"/")))
  end

  def show(conn, %{"token_id" => token_id}) do
    case Metadata.for_key(token_id) do
      {waiting, metadata} when waiting in [:revealing, :drawing] ->
        conn |> put_resp_header("cache-control", "max-age=30") |> json(metadata)

      {:revealed, metadata} ->
        conn |> put_resp_header("cache-control", "public, max-age=3600") |> json(metadata)

      :not_found ->
        KeyfleetWeb.Refusal.json(conn, 404, "key_not_found")
    end
  end
end
