defmodule KeyFleet.Keeper do
  @moduledoc """
  The record of what the keeper sent and of its rounds. Only the keeper,
  acting as the system, reads or writes it.
  """
  use Ash.Domain

  alias KeyFleet.Actors.System
  alias KeyFleet.Keeper.Transaction

  resources do
    resource KeyFleet.Keeper.Transaction do
      define :record_sent_tx, action: :record_sent
    end

    resource KeyFleet.Keeper.Run do
      define :record_run, action: :record
    end
  end

  @doc """
  Writes a transaction's outcome, in one update that finds the row only while
  it has none. Returns `{:ok, tx}`, `{:error, :settled}` when it already has
  one, `{:error, :not_found}` when there is no such transaction, or
  `{:error, error}`.
  """
  def settle(%Transaction{id: id}, outcome) do
    Transaction
    |> Ash.Query.for_read(:unsettled, %{id: id})
    |> Ash.bulk_update(:settle, outcome,
      strategy: :atomic,
      return_records?: true,
      return_errors?: true,
      rollback_on_error?: false,
      actor: %System{}
    )
    |> case do
      %Ash.BulkResult{status: :success, records: [tx]} -> {:ok, tx}
      %Ash.BulkResult{status: :success, records: []} -> settled_or_missing(id)
      %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
    end
  end

  defp settled_or_missing(id) do
    case Ash.get(Transaction, id, actor: %System{}, not_found_error?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, _tx} -> {:error, :settled}
      {:error, error} -> {:error, error}
    end
  end
end
