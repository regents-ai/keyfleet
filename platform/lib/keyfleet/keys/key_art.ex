defmodule Keyfleet.Keys.KeyArt do
  @moduledoc """
  A revealed key's card picture: the key-art service (`key-art/` at the
  repository root) that draws it, and the address it is shown at once it is
  kept on IPFS (`Keyfleet.Lighthouse`).

  The same seed, table and top line always give the same picture, so a key
  revealed again with another seed gets another picture at another address.

  The service is configured under `:keyfleet, Keyfleet.Keys.KeyArt`: its `url`
  and `req_options` (the tests' `Req.Test` stub). Each draw is asked once;
  the picture job retries.
  """

  @origin "https://media.regents.sh"

  @doc "Where every card picture is shown from."
  def origin, do: @origin

  @doc "The address a card kept on IPFS at `cid` is shown at."
  def link(cid), do: "#{@origin}/ipfs/#{cid}"

  @doc """
  Has the service draw the card of the key with `seed` from the trait table
  `trait_table_hash`, with `top_line` printed on it: `{:ok, png}` or
  `{:error, reason}`.
  """
  def draw(seed, top_line, trait_table_hash) do
    config = Application.fetch_env!(:keyfleet, __MODULE__)

    Req.post(
      [
        base_url: config[:url],
        url: "/draw",
        json: %{seed: seed, top_line: top_line, table: trait_table_hash},
        decode_body: false,
        retry: false,
        redirect: false,
        # The service's machine may be asleep and wake for this request. Its
        # private Flycast address has only an IPv6 record.
        connect_options: [timeout: 15_000, transport_opts: [inet6: true]],
        receive_timeout: 150_000
      ] ++ config[:req_options]
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: <<0x89, "PNG", _rest::binary>> = png}} ->
        {:ok, png}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:key_art_status, status, body}}

      {:error, error} ->
        {:error, error}
    end
  end
end
