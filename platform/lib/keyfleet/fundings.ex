defmodule Keyfleet.Fundings do
  @moduledoc """
  Fundings of a fleet's treasury paid in NEAR: a member asks for an amount of
  USDC, names their NEAR account for refunds, and sends NEAR from their own
  wallet to the deposit address the NEAR Intents 1Click service answers. The
  service swaps it and sends the USDC to the fleet's own treasury address on
  Base, which is always the recipient. The site only asks for prices and
  reads how a deposit stands; it never holds or moves funds.

  The client is the one `config :keyfleet, Keyfleet.Fundings, client: ...`
  names: `RegentNearIntents`, or a stub in tests.
  """
  use Ash.Domain

  resources do
    resource Keyfleet.Fundings.Funding do
      define :price_funding, action: :price, args: [:fleet_id, :usdc_amount, :refund_to]
      define :start_funding, action: :start, args: [:fleet_id, :usdc_amount, :refund_to]
      define :list_fundings, action: :of_fleet, args: [:fleet_id]

      define :get_funding,
        action: :in_fleet,
        args: [:fleet_id, :id],
        get?: true,
        not_found_error?: false

      define :refresh_funding, action: :refresh
    end
  end

  alias Keyfleet.Fundings.Errors.{NotLive, ServiceFailed}

  @doc """
  The service's quote for `usdc_amount` USDC (base units) landing at the
  fleet's treasury address on Base, refunded to the NEAR account `refund_to`:
  a price when `dry`, with a deposit address when not. The answer carries
  the `recipient` it was asked for.
  """
  def quote(fleet_id, usdc_amount, refund_to, dry) do
    with {:ok, treasury} <- treasury(fleet_id),
         {:ok, quote} <-
           ask(
             client().quote(%{
               usdc_amount: usdc_amount,
               recipient: treasury,
               refund_to: refund_to,
               dry: dry
             })
           ) do
      {:ok, Map.put(quote, :recipient, treasury)}
    end
  end

  @doc "How the deposit to `deposit_address` stands, as the service reads it."
  def status(deposit_address), do: ask(client().status(deposit_address))

  defp ask({:ok, answer}), do: {:ok, answer}

  defp ask({:error, %{reason: reason, message: message}}),
    do: {:error, ServiceFailed.exception(reason: reason, message: message)}

  defp client, do: Application.fetch_env!(:keyfleet, __MODULE__)[:client]

  # The fleet's treasury address on Base, as its recorded deployment names it:
  # where every funding's USDC lands. A fleet not yet on chain has none.
  defp treasury(fleet_id) do
    case Keyfleet.Fleets.get_fleet!(fleet_id) do
      %{treasury_address: "0x" <> _rest = address} -> {:ok, address}
      _not_live -> {:error, NotLive.exception(fleet_id: fleet_id)}
    end
  end
end
