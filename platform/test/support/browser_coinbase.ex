defmodule Keyfleet.BrowserCoinbase do
  @moduledoc """
  Coinbase's list of products as the browser test server answers it from the
  moment that server starts (config/runtime.exs names it there), so the list a
  pick may name (`Keyfleet.Seasons.CoinList`) is read on that server as on the
  site: SOL-USD and ETH-USD, beside USDC, in the shape `Keyfleet.CoinbaseStub`
  answers. No walk asks Coinbase.
  """

  @behaviour Plug

  alias Keyfleet.CoinbaseStub

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/market/products"} = conn, _opts) do
    products = Enum.map(["SOL-USD", "ETH-USD"], &CoinbaseStub.product/1)

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
end
