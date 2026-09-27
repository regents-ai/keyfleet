defmodule Keyfleet.Treasury do
  @moduledoc """
  A fleet's money as its contract reports it: amounts its budget took in,
  income paid to the keys, payments out of the budget, the latest reading of
  its balances, and the symbol and decimals of each asset they name. Recorded from the fleet's contracts by the chain
  reader and by nothing else. The chain is the authority; these records only
  mirror it.
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Treasury.{BudgetPayment, IncomeReceipt}

  @latest 20

  resources do
    resource Keyfleet.Treasury.Reading do
      define :record_reading, action: :record
      define :get_reading, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Treasury.AssetDetails do
      define :record_asset_details, action: :record
      define :asset_details, action: :of_fleet, args: [:fleet_id]
      define :details_of_assets, action: :of_assets, args: [:fleet_id, :assets]
    end

    resource Keyfleet.Treasury.BudgetReceipt do
      define :record_budget_receipt, action: :record

      define :budget_receipts_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource Keyfleet.Treasury.IncomeReceipt do
      define :record_income_receipt, action: :record

      define :income_receipts_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource Keyfleet.Treasury.BudgetPayment do
      define :record_budget_payment, action: :record

      define :budget_payments_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end
  end

  @doc """
  Every budget receipt, income receipt and budget payment recorded from blocks
  `from..to` of the fleet, so a second reading of them can be checked against
  the record.
  """
  def recorded_in_blocks!(fleet_id, from, to) do
    Enum.flat_map(
      [
        &budget_receipts_recorded_in_blocks!/4,
        &income_receipts_recorded_in_blocks!/4,
        &budget_payments_recorded_in_blocks!/4
      ],
      & &1.(fleet_id, from, to, actor: %System{})
    )
  end

  @doc """
  What an amount of the fleet's assets is shown with: `%{usdc: address,
  details: %{asset => {symbol, decimals}}}`, the fleet's USDC and each
  asset's symbol and decimals as its token reported them, either nil when
  the token has not said. `assets/2` reads the details of the `assets` named
  only.
  """
  def assets(fleet), do: shown_with(fleet, asset_details!(fleet.id))

  def assets(fleet, assets), do: shown_with(fleet, details_of_assets!(fleet.id, assets))

  defp shown_with(fleet, details) do
    %{usdc: fleet.usdc_address, details: Map.new(details, &{&1.asset, {&1.symbol, &1.decimals}})}
  end

  @doc """
  The fleet's latest #{@latest} income receipts and budget payments,
  newest first, and whether earlier ones were recorded.
  """
  def latest(fleet_id),
    do: %{income: latest(IncomeReceipt, fleet_id), payments: latest(BudgetPayment, fleet_id)}

  defp latest(resource, fleet_id) do
    {shown, earlier} =
      resource
      |> Ash.Query.filter(fleet_id == ^fleet_id)
      |> Ash.Query.sort(record_seq: :desc)
      |> Ash.Query.limit(@latest + 1)
      |> Ash.read!()
      |> Enum.split(@latest)

    %{shown: shown, earlier?: earlier != []}
  end
end
