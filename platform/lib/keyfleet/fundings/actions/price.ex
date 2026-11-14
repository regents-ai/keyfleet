defmodule Keyfleet.Fundings.Actions.Price do
  @moduledoc """
  The price of a funding, asked of the service without starting one: the
  NEAR to send, the USDC that lands, the seconds it expects and the fleet's
  treasury address it lands at.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, quote} <-
           Keyfleet.Fundings.quote(
             input.arguments.fleet_id,
             input.arguments.usdc_amount,
             input.arguments.refund_to,
             true
           ) do
      {:ok,
       %{
         near_in: Decimal.new(quote.amount_in),
         near_in_formatted: quote.amount_in_formatted,
         usdc_out_formatted: quote.amount_out_formatted,
         seconds: quote.time_estimate_s,
         recipient: quote.recipient
       }}
    end
  end
end
