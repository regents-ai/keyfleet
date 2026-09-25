defmodule Keyfleet.Treasury do
  @moduledoc """
  A fleet's budget as its contract reports it: assets received into it,
  launch income split between the budget and the keys, payments out of the
  budget, the latest reading of its balances, and the symbol and decimals of
  each asset they name. Recorded from the fleet's contracts by the chain
  reader and by nothing else. The chain is the authority; these records only
  mirror it.
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Treasury.{BudgetPayment, BudgetReceipt, IncomeSplit}

  @latest 20

  resources do
    resource Keyfleet.Treasury.Reading do
      define :record_reading, action: :record
      define :get_reading, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Treasury.AssetDetails do
      define :record_asset_details, action: :record
      define :asset_details, action: :of_fleet, args: [:fleet_id]
    end

    resource Keyfleet.Treasury.BudgetReceipt do
      define :record_budget_receipt, action: :record

      define :budget_receipts_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource Keyfleet.Treasury.IncomeSplit do
      define :record_income_split, action: :record

      define :income_splits_recorded_in_blocks,
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
  Every budget receipt, income split and budget payment recorded from blocks
  `from..to` of the fleet, so a second reading of them can be checked against
  the record.
  """
  def recorded_in_blocks!(fleet_id, from, to) do
    Enum.flat_map(
      [
        &budget_receipts_recorded_in_blocks!/4,
        &income_splits_recorded_in_blocks!/4,
        &budget_payments_recorded_in_blocks!/4
      ],
      & &1.(fleet_id, from, to, actor: %System{})
    )
  end

  @doc """
  Every asset the fleet's budget can hold, as its history shows them: USDC,
  which key sales pay in, then `reward_assets`, the reward ledger's assets in
  its order, then, by address, each asset received into the budget or split
  from launch income. The fleet contract takes in only the assets its
  registry admits, so the list stays as short as that.
  """
  def budget_assets(fleet, reward_assets) do
    recorded =
      [BudgetReceipt, IncomeSplit]
      |> Enum.flat_map(&assets_of(&1, fleet.id))
      |> Enum.sort()

    Enum.uniq([fleet.usdc_address | reward_assets] ++ recorded)
  end

  defp assets_of(query, fleet_id) do
    query
    |> Ash.Query.filter(fleet_id == ^fleet_id)
    |> Ash.Query.distinct(:asset)
    |> Ash.Query.select([:asset])
    |> Ash.read!()
    |> Enum.map(& &1.asset)
  end

  @doc """
  The fleet's latest #{@latest} launch income splits and budget payments,
  newest first, and whether earlier ones were recorded.
  """
  def latest(fleet_id),
    do: %{income: latest(IncomeSplit, fleet_id), payments: latest(BudgetPayment, fleet_id)}

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
