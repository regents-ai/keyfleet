defmodule KeyFleet.Treasury do
  @moduledoc """
  A fleet's budget as its contract reports it: launch income split between
  the budget and the keys, and payments out of the budget. Recorded from the
  fleet contract by the chain reader and by nothing else. The chain is the
  authority; these records only mirror it.
  """
  use Ash.Domain

  alias KeyFleet.Actors.System

  resources do
    resource KeyFleet.Treasury.IncomeSplit do
      define :record_income_split, action: :record

      define :income_splits_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource KeyFleet.Treasury.BudgetPayment do
      define :record_budget_payment, action: :record

      define :budget_payments_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end
  end

  @doc """
  Every income split and budget payment recorded from blocks `from..to` of the
  fleet, so a second reading of them can be checked against the record.
  """
  def recorded_in_blocks!(fleet_id, from, to) do
    Enum.flat_map(
      [&income_splits_recorded_in_blocks!/4, &budget_payments_recorded_in_blocks!/4],
      & &1.(fleet_id, from, to, actor: %System{})
    )
  end
end
