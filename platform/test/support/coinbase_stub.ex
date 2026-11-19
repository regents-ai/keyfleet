defmodule Keyfleet.CoinbaseStub do
  @moduledoc """
  Coinbase's public market data answered by `Req.Test` for
  `Keyfleet.Seasons.Coinbase`, in the shapes of Coinbase's reference (List
  Public Products, Get Public Product Candles) and its errors. No test calls
  Coinbase.
  """

  alias Keyfleet.Seasons.Coinbase

  @doc """
  A spot product quoted in US dollars, open for trading and traded well over
  the floor, as the list of products shows it, with `overrides`.
  """
  def product(product_id, overrides \\ %{}) do
    [base, _quote] = String.split(product_id, "-")

    Map.merge(
      %{
        "product_id" => product_id,
        "price" => "73.16",
        "price_percentage_change_24h" => "0.88251516822945",
        "volume_24h" => "1097135.34579776",
        "volume_percentage_change_24h" => "-37.72578624023114",
        "base_increment" => "0.00000001",
        "quote_increment" => "0.01",
        "quote_min_size" => "1",
        "quote_max_size" => "25000000",
        "base_min_size" => "0.00000001",
        "base_max_size" => "1274000",
        "base_name" => base,
        "quote_name" => "US Dollar",
        "watched" => false,
        "is_disabled" => false,
        "new" => false,
        "status" => "online",
        "cancel_only" => false,
        "limit_only" => false,
        "post_only" => false,
        "trading_disabled" => false,
        "auction_mode" => false,
        "product_type" => "SPOT",
        "quote_currency_id" => "USD",
        "base_currency_id" => base,
        "mid_market_price" => "",
        "alias" => "",
        "alias_to" => [],
        "base_display_symbol" => base,
        "quote_display_symbol" => "USD",
        "view_only" => false,
        "price_increment" => "0.01",
        "display_name" => product_id,
        "product_venue" => "CBE",
        "approximate_quote_24h_volume" => "80266421.9",
        "new_at" => "2023-01-01T00:00:00Z"
      },
      overrides
    )
  end

  @doc """
  Answers the list of products with `products`, and each product's one-minute
  candles from `closes`: `%{product_id => [{minute_start, close}]}`, where
  `minute_start` is a `DateTime` and `close` the decimal string Coinbase
  sends. A product missing from `closes` is one Coinbase doesn't know, and one
  given `:down` has candles Coinbase doesn't answer for.
  """
  def stub(products, closes) do
    Req.Test.stub(Coinbase, fn conn ->
      case String.split(conn.request_path, "/", trim: true) do
        ["market", "products"] -> listed(conn, products)
        ["market", "products", product_id, "candles"] -> candles(conn, closes, product_id)
      end
    end)
  end

  @doc """
  Answers the list of spot products in `pages`, one list of products for each
  page, every page but the last naming the next by its cursor.
  """
  def pages(pages) do
    Req.Test.stub(Coinbase, fn conn ->
      query = conn.query_string |> URI.query_decoder() |> Map.new()
      "SPOT" = query["product_type"]

      page =
        query |> Map.get("cursor", Base.encode64("0")) |> Base.decode64!() |> String.to_integer()

      products = Enum.at(pages, page)
      has_next = page < length(pages) - 1

      Req.Test.json(conn, %{
        "products" => products,
        "num_products" => length(products),
        "pagination" => %{
          "prev_cursor" => "",
          "next_cursor" => if(has_next, do: Base.encode64(Integer.to_string(page + 1)), else: ""),
          "has_next" => has_next,
          "has_prev" => page > 0
        }
      })
    end)
  end

  @doc "Coinbase answering every request 503."
  def down, do: Req.Test.stub(Coinbase, &unavailable/1)

  defp unavailable(conn) do
    conn
    |> Plug.Conn.put_status(503)
    |> Req.Test.json(%{
      "error" => "UNAVAILABLE",
      "code" => 14,
      "message" => "service unavailable",
      "details" => []
    })
  end

  # The whole list of spot products on one page.
  defp listed(conn, products) do
    %{"product_type" => "SPOT"} = conn.query_string |> URI.query_decoder() |> Map.new()

    Req.Test.json(conn, %{
      "products" => products,
      "num_products" => length(products),
      "pagination" => %{
        "prev_cursor" => "",
        "next_cursor" => "",
        "has_next" => false,
        "has_prev" => false
      }
    })
  end

  # Every candle from `start` to `end`, both included, newest first. Coinbase
  # answers at most 350 candles a request.
  defp candles(conn, closes, product_id) do
    query = Map.new(URI.query_decoder(conn.query_string))
    first = String.to_integer(query["start"])
    last = String.to_integer(query["end"])
    "ONE_MINUTE" = query["granularity"]
    true = div(last - first, 60) < 350

    case Map.fetch(closes, product_id) do
      {:ok, :down} ->
        unavailable(conn)

      {:ok, minutes} ->
        candles =
          for {at, close} <- minutes,
              start = DateTime.to_unix(at),
              start >= first and start <= last do
            %{
              "start" => Integer.to_string(start),
              "low" => close,
              "high" => close,
              "open" => close,
              "close" => close,
              "volume" => "533.02452003"
            }
          end

        Req.Test.json(conn, %{"candles" => Enum.sort_by(candles, & &1["start"], :desc)})

      :error ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "INVALID_ARGUMENT",
          "error_details" => "valid product_id is required",
          "message" => "valid product_id is required"
        })
    end
  end
end
