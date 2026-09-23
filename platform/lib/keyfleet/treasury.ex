defmodule KeyFleet.Treasury do
  @moduledoc """
  A fleet's budget as its contract reports it: launch income split between
  the budget and the keys, payments out of the budget, and the latest
  reading of its balances. Recorded from the fleet's contracts by the chain
  reader and by nothing else. The chain is the authority; these records only
  mirror it.
  """
  use Ash.Domain

  require Ash.Query

  alias KeyFleet.Actors.System
  alias KeyFleet.Treasury.{BudgetPayment, IncomeSplit}

  @latest 20

  resources do
    resource KeyFleet.Treasury.Reading do
      define :record_reading, action: :record
      define :get_reading, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

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
