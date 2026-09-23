defmodule KeyFleetWeb.MetadataController do
  @moduledoc """
  Serves each key's ERC-721 metadata at the path its fleet's `tokenURI`
  names. A key still being revealed is cached for 30 seconds and a revealed
  key for an hour, so a record corrected by hand and new pictures show soon.
  """
  use KeyFleetWeb, :controller

  alias KeyFleet.Keys.Metadata

  def show(conn, %{"slot" => slot, "token_id" => token_id}) do
    case Metadata.for_key(slot, token_id, KeyFleetWeb.Endpoint.url()) do
      {:revealing, metadata} ->
        conn |> put_resp_header("cache-control", "max-age=30") |> json(metadata)

      {:revealed, metadata} ->
        conn |> put_resp_header("cache-control", "public, max-age=3600") |> json(metadata)

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "key_not_found"})
    end
  end
end
