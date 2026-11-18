defmodule Keyfleet.Seasons.Errors.SeasonUnknownError do
  @moduledoc "Raised when a fleet has no season with the number a caller named."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "this fleet has no season #{number}"
end

defmodule Keyfleet.Seasons.Errors.PicksClosedError do
  @moduledoc "Raised when a pick arrives for a season that has started."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "season #{number} has started; its picks are final"
end

defmodule Keyfleet.Seasons.Errors.ProductIneligibleError do
  @moduledoc """
  Raised when a pick names a product that may not be picked now: not on
  Coinbase as spot, quoted in US dollars and open for trading, or traded too
  little over the last 24 hours.
  """
  use Splode.Error, fields: [:product], class: :invalid

  def message(%{product: product}), do: "#{product} may not be picked now"
end

defmodule Keyfleet.Seasons.Errors.ProductsUnreadError do
  @moduledoc """
  Raised when a pick arrives while the products that may be picked have not
  been read from Coinbase. Nothing was written.
  """
  use Splode.Error, fields: [], class: :framework

  def message(_error),
    do: "the products that may be picked could not be read just now; nothing was written"
end
