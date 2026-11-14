defmodule KeyfleetWeb.FundingJSON do
  @moduledoc """
  A funding of a fleet's treasury with NEAR (`Keyfleet.Fundings.Funding`) as
  the agent API and the agent tools answer it, with links to both chains'
  explorers and, once the USDC has landed, its receipt.
  """

  alias Keyfleet.Fundings.Funding

  @status %{
    pending_deposit: "Waiting",
    processing: "Processing",
    success: "Arrived",
    refunded: "Refunded",
    failed: "Failed"
  }

  @doc "The funding's JSON."
  @spec funding(Funding.t()) :: map()
  def funding(%Funding{} = funding) do
    %{
      id: funding.id,
      fleet_id: funding.fleet_id,
      state: Atom.to_string(funding.state),
      status: Map.fetch!(@status, funding.state),
      usdc_amount: funding.usdc_amount,
      usdc: usdc(funding.usdc_amount),
      recipient: funding.recipient,
      refund_to: funding.refund_to,
      near_in: Decimal.to_string(funding.near_in, :normal),
      near_in_formatted: funding.near_in_formatted,
      deposit_address: funding.deposit_address,
      deadline: funding.deadline,
      time_estimate_s: funding.time_estimate_s,
      origin_tx: funding.origin_tx,
      destination_tx: funding.destination_tx,
      origin_tx_url: funding.origin_tx && "https://nearblocks.io/txns/#{funding.origin_tx}",
      destination_tx_url:
        funding.destination_tx && "https://basescan.org/tx/#{funding.destination_tx}",
      receipt: receipt(funding),
      inserted_at: funding.inserted_at
    }
  end

  @doc "USDC base units (6 decimals) written out, such as `\"5.000000\"`."
  @spec usdc(non_neg_integer()) :: String.t()
  def usdc(amount),
    do:
      amount
      |> Decimal.new()
      |> Decimal.div(1_000_000)
      |> Decimal.round(6)
      |> Decimal.to_string(:normal)

  defp receipt(%Funding{state: :success} = funding) do
    %{
      usdc: usdc(funding.usdc_amount),
      recipient: funding.recipient,
      origin_tx: funding.origin_tx,
      destination_tx: funding.destination_tx,
      finished_at: funding.finished_at,
      signature: "not_checked"
    }
  end

  defp receipt(_funding), do: nil
end
