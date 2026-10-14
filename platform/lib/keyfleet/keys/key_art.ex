defmodule Keyfleet.Keys.KeyArt do
  @moduledoc """
  A revealed key's card picture: the key-art service (`key-art/` at the
  repository root) that draws it, and the address it is shown at once it is
  kept on IPFS (`Keyfleet.Lighthouse`).

  The same seed, table and top line always give the same picture, so a key
  revealed again with another seed gets another picture at another address.

  A card also has a close-up, for places that show many Keys at once (the
  fleet's map, a holder's cards): the square at the card's middle, small
  enough to load by the hundred. It is cut from the card as it is kept, so it
  is always that card's own picture.

  The service is configured under `:keyfleet, Keyfleet.Keys.KeyArt`: its `url`
  and `req_options` (the tests' `Req.Test` stub). Each draw and each read of a
  kept card is asked once; the jobs retry.
  """

  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @origin "https://media.regents.sh"

  # A card's size in pixels, as the key-art service draws it.
  @card_width 767
  @card_height 959

  # The close-up: a square of this side around the card's middle, which holds
  # the medallion wherever the card's slot puts it, kept at `@close_up_side`.
  @cut_side 448
  @close_up_side 256

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

  @doc """
  The card kept on IPFS at `cid`, read back from where it is shown:
  `{:ok, png}` or `{:error, reason}`.
  """
  def kept(cid) do
    config = Application.fetch_env!(:keyfleet, __MODULE__)

    Req.get(
      [
        url: link(cid),
        decode_body: false,
        retry: false,
        redirect: false,
        receive_timeout: 60_000
      ] ++ config[:req_options]
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: <<0x89, "PNG", _rest::binary>> = png}} ->
        {:ok, png}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:kept_card_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The close-up of the card `png`, as a WebP: `{:ok, webp}`, or
  `{:error, reason}` for a picture that is not a card.
  """
  def close_up(png) do
    left = div(@card_width - @cut_side, 2)
    top = div(@card_height - @cut_side, 2)

    with {:ok, card} <- Image.new_from_buffer(png),
         :ok <- card_sized(card),
         {:ok, cut} <- Operation.extract_area(card, left, top, @cut_side, @cut_side),
         {:ok, small} <- Operation.resize(cut, @close_up_side / @cut_side) do
      Image.write_to_buffer(small, ".webp[Q=82]")
    end
  end

  # Only the picture's first bytes are read to learn its size, so a picture
  # of any other size is turned away before it is opened in full.
  defp card_sized(card) do
    case {Image.width(card), Image.height(card)} do
      {@card_width, @card_height} -> :ok
      size -> {:error, {:not_a_card, size}}
    end
  end
end
