defmodule Keyfleet.Fundings.Changes.AskQuote do
  @moduledoc """
  Asks the service for a real quote, before the funding's transaction opens,
  for the USDC asked to land at the fleet's own treasury address, and records
  what it answered: the NEAR to send, the deposit address, the time it
  expects and the deadline.
  """
  use Ash.Resource.Change

  alias Keyfleet.Fundings

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      case Fundings.quote(
             Ash.Changeset.get_attribute(changeset, :fleet_id),
             Ash.Changeset.get_attribute(changeset, :usdc_amount),
             Ash.Changeset.get_attribute(changeset, :refund_to),
             false
           ) do
        {:ok, quote} ->
          Ash.Changeset.force_change_attributes(changeset, %{
            recipient: quote.recipient,
            near_in: quote.amount_in,
            near_in_formatted: quote.amount_in_formatted,
            time_estimate_s: quote.time_estimate_s,
            deadline: quote.deadline,
            deposit_address: quote.deposit_address
          })

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
