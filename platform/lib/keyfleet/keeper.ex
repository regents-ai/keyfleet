defmodule KeyFleet.Keeper do
  @moduledoc """
  The record of what the keeper sent and of its rounds. Only the keeper,
  acting as the system, reads or writes it.
  """
  use Ash.Domain

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Keeper.Transaction

  resources do
    resource KeyFleet.Keeper.Transaction do
      define :record_sent_tx, action: :record_sent
      define :list_outstanding_txs, action: :outstanding, args: [:chain_id, :from_address]
      define :list_latest_txs, action: :latest, args: [:chain_id, :from_address]

      define :list_recent_txs,
        action: :recent,
        args: [:chain_id, :from_address, :fleet_id, :function, :since]

      define :last_settled_tx,
        action: :last_settled,
        args: [:chain_id, :from_address],
        not_found_error?: false
    end

    resource KeyFleet.Keeper.Run do
      define :record_run, action: :record
      define :last_run, action: :last, args: [:job], not_found_error?: false
      define :stop_state, action: :stop_state, not_found_error?: false

      define :pause_state,
        action: :pause_state,
        args: [:outcomes, :fleet_id],
        not_found_error?: false
    end
  end

  @day_seconds 86_400

  # Each kind of pause, with the outcomes that begin and end it.
  @pauses %{
    gas: [:paused_gas, :unpaused_gas],
    vrf_balance: [:paused_vrf_balance, :unpaused_vrf_balance],
    spend_ceiling: [:paused_spend_ceiling, :unpaused_spend_ceiling]
  }

  @doc """
  The wallet's spending on the chain over the last 24 hours, in wei:
  `settled`, what the transactions with an outcome cost, and `waiting`, for
  each nonce still waiting, the most its transactions could cost, which is
  the gas limit times the maximum fee of the dearest one; only one of them
  can be included. Returns `{:ok, spend}` or `{:error, error}`.
  """
  def spend(chain_id, from_address) do
    since = DateTime.add(DateTime.utc_now(), -@day_seconds)

    Transaction
    |> Ash.Query.for_read(
      :toward_spend,
      %{chain_id: chain_id, from_address: from_address, since: since},
      actor: %System{}
    )
    |> Ash.read()
    |> case do
      {:ok, txs} -> {:ok, %{settled: settled(txs), waiting: waiting(txs)}}
      {:error, error} -> {:error, error}
    end
  end

  defp settled(txs),
    do: Enum.sum(for %Transaction{cost_wei: cost} when is_integer(cost) <- txs, do: cost)

  defp waiting(txs) do
    for %Transaction{status: nil} = tx <- txs, reduce: %{} do
      waiting -> Map.update(waiting, tx.nonce, worst_case(tx), &Kernel.max(&1, worst_case(tx)))
    end
  end

  @doc "An amount in wei, written in ETH."
  def eth(wei),
    do:
      wei |> Decimal.new() |> Decimal.div(1_000_000_000_000_000_000) |> Decimal.to_string(:normal)

  # The most a transaction can cost: its gas limit at its maximum fee.
  defp worst_case(%Transaction{gas_limit: gas_limit, max_fee: max_fee}), do: gas_limit * max_fee

  @doc """
  Records that a pause of `job` began or ended, with `outcome` naming which
  of the two and its kind, `notes` saying what happened, and the fleet a
  VRF balance pause is for. A record that cannot be written is logged and
  left: the pause itself goes on regardless.
  """
  def record_pause(job, outcome, notes, fleet_id \\ nil) do
    now = DateTime.utc_now()

    case record_run(
           %{
             job: job,
             started_at: now,
             finished_at: now,
             outcome: outcome,
             fleet_id: fleet_id,
             sent: 0,
             skipped: 0,
             notes: String.slice(notes, 0, 2_000)
           },
           actor: %System{}
         ) do
      {:ok, _run} -> :ok
      {:error, error} -> Logger.warning("Keeper could not record a pause: #{inspect(error)}")
    end
  end

  @doc """
  Whether the latest record of a `pause` (`:gas`, `:vrf_balance` for
  `fleet_id`, or `:spend_ceiling`) says it began and has not ended:
  `{:ok, in_force?}` or `{:error, error}`.
  """
  def pause_in_force(pause, fleet_id \\ nil) do
    [began, _ended] = outcomes = Map.fetch!(@pauses, pause)

    case pause_state(outcomes, fleet_id, actor: %System{}) do
      {:ok, run} -> {:ok, match?(%{outcome: ^began}, run)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Records a round of `job` that sent something, begun at `started_at`, with
  how many it sent and passed over. A record that cannot be written is
  logged and left.
  """
  def record_round(job, started_at, %{sent: sent, skipped: skipped}) do
    case record_run(
           %{
             job: job,
             started_at: started_at,
             finished_at: DateTime.utc_now(),
             outcome: :sent,
             sent: sent,
             skipped: skipped
           },
           actor: %System{}
         ) do
      {:ok, _run} -> :ok
      {:error, error} -> Logger.warning("Keeper could not record its round: #{inspect(error)}")
    end
  end

  @doc """
  Records that the keeper stopped during `job` for `reason`, with the
  `message` its alert gave. It stays stopped until `resume/0`.
  """
  def record_stop(job, reason, message) do
    now = DateTime.utc_now()

    record_run(
      %{
        job: job,
        started_at: now,
        finished_at: now,
        outcome: :stopped,
        stop_reason: reason,
        sent: 0,
        skipped: 0,
        notes: String.slice(message, 0, 2_000)
      },
      actor: %System{}
    )
  end

  @doc """
  The run that stopped the keeper, while nothing has resumed it:
  `{:ok, run}`, `{:ok, nil}` when it is not stopped, or `{:error, error}`.
  """
  def stopped do
    case stop_state(actor: %System{}) do
      {:ok, %{outcome: :stopped} = run} -> {:ok, run}
      {:ok, _resumed_or_nil} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Clears the keeper's stop: `{:ok, run}` with the stop it cleared,
  `{:ok, nil}` when it was not stopped, or `{:error, error}`.
  """
  def resume do
    with {:ok, %{} = stop} <- stopped(),
         # Always after the stop, so the latest of the two is never in doubt.
         now =
           Enum.max(
             [DateTime.utc_now(), DateTime.add(stop.finished_at, 1, :microsecond)],
             DateTime
           ),
         {:ok, _resumed} <-
           record_run(
             %{
               job: stop.job,
               started_at: now,
               finished_at: now,
               outcome: :resumed,
               sent: 0,
               skipped: 0
             },
             actor: %System{}
           ) do
      {:ok, stop}
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
