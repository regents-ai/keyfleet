defmodule Keyfleet.Seasons.Coinbase do
  @moduledoc """
  Coinbase's public market data, read with no account, key or secret: which
  products a season's picks may name, and a product's price at a boundary.

  A product may be picked when Coinbase's list of products
  (`GET /market/products`) shows it as spot, quoted in US dollars and open for
  trading (not disabled, trading not disabled, not view-only, not cancel-only,
  not limit-only, not in auction mode), with at least 1,000,000 US dollars
  traded over the last 24 hours (`approximate_quote_24h_volume`). `USDC`
  always may.

  A product's price at boundary T is the close of the one-minute candle that
  started at T - 60 s (`GET /market/products/{product_id}/candles`), or, when
  that minute had no trade, the newest one-minute close of the 15 minutes
  before T. With none it has no price. `USDC`'s price is 1. Prices are the
  decimals Coinbase sent.

  A product Coinbase no longer knows has no price. Any other answer but a
  reading is an error, and nothing is decided on it.

  The address comes from `config :keyfleet, Keyfleet.Seasons.Coinbase, url:`.
  """

  # The least a product must have traded over 24 hours, in US dollars, to be picked.
  @volume_floor Decimal.new(1_000_000)

  @usdc "USDC"

  # Every spot product quoted in US dollars is named this way on Coinbase.
  @usd_product ~r/\A[A-Z0-9]+-USD\z/

  @doc "The ids of every product that may be picked now, `USDC` among them."
  @spec eligible() :: {:ok, [String.t()]} | {:error, term()}
  def eligible do
    with {:ok, products} <- products([]), do: {:ok, [@usdc | eligible_ids(products)]}
  end

  @doc "Which of `product_ids` may be picked now."
  @spec eligible_among([String.t()]) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def eligible_among(product_ids) do
    {usdc, listed} = Enum.split_with(product_ids, &(&1 == @usdc))

    with {:ok, products} <- listed(listed),
         do: {:ok, MapSet.new(usdc ++ eligible_ids(products))}
  end

  @doc "`product_id`'s price at `boundary`, or nil for none."
  @spec price(String.t(), DateTime.t()) :: {:ok, Decimal.t() | nil} | {:error, term()}
  def price(@usdc, _boundary), do: {:ok, Decimal.new(1)}

  def price(product_id, %DateTime{} = boundary) do
    last = DateTime.to_unix(boundary) - 60
    first = last - 14 * 60

    case get("/market/products/:product_id/candles",
           path_params: [product_id: product_id],
           params: [start: first, end: last, granularity: "ONE_MINUTE"]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"candles" => candles}}} ->
        {:ok, newest_close(candles, first..last//60)}

      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => "INVALID_ARGUMENT", "error_details" => "valid product_id is required"}
       }} ->
        {:ok, nil}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:coinbase, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc false
  def eligible?(%{
        "product_id" => product_id,
        "product_type" => "SPOT",
        "quote_currency_id" => "USD",
        "is_disabled" => false,
        "trading_disabled" => false,
        "view_only" => false,
        "cancel_only" => false,
        "limit_only" => false,
        "auction_mode" => false,
        "approximate_quote_24h_volume" => volume
      })
      when is_binary(volume) do
    with true <- Regex.match?(@usd_product, product_id),
         {%Decimal{coef: coef} = volume, ""} when is_integer(coef) <- Decimal.parse(volume) do
      not Decimal.lt?(volume, @volume_floor)
    else
      _otherwise -> false
    end
  end

  def eligible?(_product), do: false

  defp eligible_ids(products),
    do: for(%{"product_id" => id} = product <- products, eligible?(product), do: id)

  defp listed([]), do: {:ok, []}
  defp listed(product_ids), do: products(Enum.map(product_ids, &{:product_ids, &1}))

  # Every page of the list, following its cursor.
  defp products(params) do
    case get("/market/products", params: params) do
      {:ok, %Req.Response{status: 200, body: %{"products" => products} = body}} ->
        next_page(products, body["pagination"], params)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:coinbase, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp next_page(products, %{"has_next" => true, "next_cursor" => cursor}, params) do
    with {:ok, rest} <- products(Keyword.put(params, :cursor, cursor)),
         do: {:ok, products ++ rest}
  end

  defp next_page(products, _last_page, _params), do: {:ok, products}

  defp newest_close(candles, minutes) do
    candles
    |> Enum.map(fn %{"start" => start, "close" => close} -> {String.to_integer(start), close} end)
    |> Enum.filter(fn {start, _close} -> start in minutes end)
    |> Enum.max_by(fn {start, _close} -> start end, fn -> nil end)
    |> case do
      {_start, close} -> Decimal.new(close)
      nil -> nil
    end
  end

  defp get(path, options) do
    config = Application.fetch_env!(:keyfleet, __MODULE__)

    Req.get(
      [
        base_url: Keyword.fetch!(config, :url),
        url: path,
        retry: false,
        redirect: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 15_000
      ] ++ options ++ Keyword.fetch!(config, :req_options)
    )
  end
end
