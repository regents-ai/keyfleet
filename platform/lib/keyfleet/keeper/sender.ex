defmodule Keyfleet.Keeper.Sender do
  @moduledoc """
  The one way a keeper transaction reaches the chain.

  A sender holds the keeper's wallet and sends only `%Call{}`s from
  `Keyfleet.Keeper.Calls`: `requestReveal` and `sendProtocolShare`, each to
  a deployed fleet on the chain the node serves.

  Before it sends it settles any transaction its wallet left waiting on the
  chain; records another wallet left are never touched. It refuses while
  the base fee is above the keeper's highest fee, whenever the wallet's
  spending over the day could go above its daily limit, and while the node
  is behind a nonce the keeper has already seen taken; both limits are set
  in the keeper's configuration (`Keyfleet.Keeper.limits/0`). It records
  each transaction before the node sees it and waits about a minute, five
  Ethereum blocks, for its receipt. One that does not arrive is raised by a
  quarter, at the same nonce, up to three times, each time only once its
  call passes the checks again; where no raise is left under the highest
  fee, the same transaction is sent again, so one the node dropped, or
  refused while the wallet was empty, still goes through.

  A nonce the keeper did not use, or a node naming another hash than the
  keeper's own, stops it. The stop is recorded and holds across restarts
  until `bin/keeper-resume` clears it.

  A node or database failure never raises here: it comes back as
  `{:error, reason, sender}`, for a later round to try again.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.{Fleets, Keeper}
  alias Keyfleet.Keeper.{Calls, Transaction, Wallet}
  alias Keyfleet.Keeper.Calls.Call

  @min_priority_fee div(1_000_000_000, 1_000)
  @reveal_gas_floor 200_000
  @receipt_polls 30
  @replacements 3
  @bigint 9_223_372_036_854_775_807

  @enforce_keys [:wallet, :node, :receipt_poll_ms, :limits]
  defstruct [
    :wallet,
    :node,
    :receipt_poll_ms,
    :limits,
    :chain_id,
    :stopped,
    :included_nonce,
    fleets: %{},
    ceiling_reached?: false,
    low_balance?: false
  ]

  @doc """
  A sender for `wallet` through `node`, which touches nothing until
  `start/1`.
  """
  def new(%Wallet{} = wallet, node) do
    %__MODULE__{
      wallet: wallet,
      node: node,
      receipt_poll_ms: Application.fetch_env!(:keyfleet, Keyfleet.Keeper)[:receipt_poll_ms],
      limits: Keeper.limits()
    }
  end

  @doc """
  Learns the node's chain, the deployed fleets, whether the keeper is
  stopped, whether a spending pause is still in force and the highest nonce
  it has seen taken, then, unless it is stopped, settles every transaction
  it left waiting. Returns
  `{:ok, sender}`, or `{:error, reason}` when any of those cannot be read.
  """
  def start(%__MODULE__{node: node, wallet: wallet} = sender) do
    with {:ok, chain_id} <- node.chain_id(),
         {:ok, fleets} <- Fleets.list_deployed_fleets(),
         {:ok, stop} <- Keeper.stopped(),
         {:ok, ceiling_reached?} <- Keeper.pause_in_force(:spend_ceiling),
         {:ok, last} <- Keeper.last_settled_tx(chain_id, wallet.address, actor: %System{}) do
      sender = %{
        sender
        | chain_id: chain_id,
          fleets: Map.new(fleets, &{&1.id, &1}),
          stopped: stop && stop.stop_reason,
          ceiling_reached?: ceiling_reached?,
          included_nonce: last && last.nonce
      }

      {:ok, sender |> settle_at_start() |> report()}
    end
  end

  defp settle_at_start(%{stopped: nil} = sender) do
    case settle_outstanding(sender) do
      {:ok, sender} ->
        sender

      # Its own alert has said why.
      {:error, :stopped, sender} ->
        sender

      {:error, :waiting, sender} ->
        Logger.warning("Keeper left a transaction waiting at start; a later round takes it up.")
        sender

      {:error, reason, sender} ->
        Logger.warning(
          "Keeper could not settle what it left waiting at start: #{inspect(reason)}"
        )

        sender
    end
  end

  defp settle_at_start(sender), do: sender

  @doc """
  Sends `call` for `job` on behalf of `fleet_id` and waits for it.

  Returns `{:ok, tx, receipt, sender}` once it is included, with `tx`'s
  status `:mined` or `:reverted`; `{:waiting, tx, sender}` when it is left
  for a later round; or `{:error, reason, sender}` when nothing was sent,
  or it could not be followed. A call the contract refuses in the gas
  estimate is `{:error, {:revert, selector, args}, sender}`.
  """
  def send(%__MODULE__{} = sender, %{job: job, fleet_id: fleet_id, call: %Call{} = call}) do
    with :ok <- running(sender),
         {:ok, fleet} <- fleet(sender, fleet_id),
         :ok <- allowed(fleet, call),
         {:ok, sender} <- settle_outstanding(sender) do
      send_next(sender, %{job: job, fleet_id: fleet_id, call: call})
    else
      {:error, reason} -> {:error, reason, sender}
      {:error, _reason, _sender} = refused -> refused
    end
  end

  # With nothing waiting: a new transaction at the wallet's next nonce.
  defp send_next(sender, %{job: job, call: call} = sending) do
    with {:ok, nonce} <- fresh_nonce(sender),
         {:ok, fees} <- fees(sender),
         {:ok, gas_limit} <- gas_limit(sender, call),
         {:ok, sender} <- within_ceiling(sender, job, nonce, gas_limit * fees.max_fee),
         {:ok, tx} <-
           transmit(
             sender,
             Map.merge(sending, %{
               nonce: nonce,
               fees: fees,
               gas_limit: gas_limit,
               replaces_tx_hash: nil
             })
           ) do
      await(sender, [tx], @replacements)
    else
      {:stop, reason, message} -> {:error, :stopped, stop(sender, job, reason, message)}
      {:error, reason} -> {:error, reason, sender}
      {:error, _reason, _sender} = refused -> refused
    end
  end

  @doc """
  Reads the wallet's balance and the day's spending, reports both as
  metrics, and raises an alert when the balance first falls under the
  keeper's low-balance mark.
  """
  def report(%__MODULE__{node: node, wallet: wallet} = sender) do
    with {:ok, balance} <- node.balance(wallet.address),
         {:ok, spent} <- spent_24h(sender) do
      :telemetry.execute(
        [:keyfleet, :keeper],
        %{wallet_balance_wei: balance, spent_24h_wei: spent},
        %{}
      )

      low? = balance < sender.limits.low_balance

      if low? and not sender.low_balance? do
        Logger.error(
          "Keeper alert: wallet under #{Keeper.eth(sender.limits.low_balance)} ETH, #{Keeper.eth(balance)} ETH left in #{wallet.address}; top it up."
        )
      end

      %{sender | low_balance?: low?}
    else
      {:error, reason} ->
        Logger.warning("Keeper could not read its balance or spending: #{inspect(reason)}")
        sender
    end
  end

  @doc """
  What the wallet spent, or may yet spend, on the sender's chain in the
  last 24 hours: `{:ok, wei}` or `{:error, error}`.
  """
  def spent_24h(%__MODULE__{chain_id: chain_id, wallet: wallet}) do
    with {:ok, %{settled: settled, waiting: waiting}} <- Keeper.spend(chain_id, wallet.address),
         do: {:ok, settled + Enum.sum(Map.values(waiting))}
  end

  @doc "The sender as it may be shown: the wallet's address in place of the wallet."
  def redact(%__MODULE__{wallet: %Wallet{address: address}} = sender),
    do: %{sender | wallet: address}

  defp running(%{stopped: nil}), do: :ok
  defp running(_sender), do: {:error, :stopped}

  defp fleet(%{fleets: fleets, chain_id: chain_id}, fleet_id) do
    case Map.fetch(fleets, fleet_id) do
      {:ok, %{chain_id: ^chain_id} = fleet} -> {:ok, fleet}
      {:ok, _fleet} -> {:error, :wrong_chain}
      :error -> {:error, :unknown_fleet}
    end
  end

  # Both of the keeper's calls go to the fleet itself.
  defp allowed(fleet, %Call{target: target}),
    do: if(target == fleet.contract_address, do: :ok, else: {:error, :foreign_target})

  @doc """
  Reads a view of `Keyfleet.Keeper.Calls` from the contract at `to`, as the
  keeper, at the latest block: `{:ok, value}`, or `{:error, reason}`, which
  is `{:revert, selector, args}` when the contract refuses.
  """
  def read(%__MODULE__{node: node, wallet: wallet}, to, view, args \\ []) do
    with {:ok, data} <- Calls.view(view, args),
         {:ok, bytes} <- node.call(wallet.address, to, data) do
      decoded(view, bytes)
    end
  end

  defp decoded(name, bytes) do
    case Calls.decode(name, bytes) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:undecodable, name}}
    end
  end

  # Settles every transaction the wallet left waiting, oldest nonce first, and
  # stops at the first that cannot be.
  defp settle_outstanding(sender) do
    case Keeper.list_outstanding_txs(sender.chain_id, sender.wallet.address, actor: %System{}) do
      {:ok, txs} ->
        txs
        |> Enum.group_by(& &1.nonce)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, sender}, &settle_next/2)

      {:error, error} ->
        {:error, error, sender}
    end
  end

  defp settle_next({_nonce, txs}, {:ok, sender}) do
    case settle_nonce(sender, Enum.sort_by(txs, & &1.max_fee, :desc)) do
      {:ok, _tx, _receipt, sender} -> {:cont, {:ok, sender}}
      {:waiting, _tx, sender} -> {:halt, {:error, :waiting, sender}}
      {:error, _reason, _sender} = error -> {:halt, error}
    end
  end

  # The chain's nonce is read before the receipts, so a transaction of ours
  # included in between is never taken for someone else's.
  defp settle_nonce(sender, [newest | _older] = txs) do
    with {:ok, latest} <- latest_nonce(sender),
         {:ok, found} <- find_receipt(sender, txs) do
      case found do
        {tx, receipt} -> settled(sender, txs, tx, receipt)
        nil when latest > newest.nonce -> confirm_replaced(sender, txs)
        nil -> replace(sender, txs, @replacements)
      end
    else
      {:error, reason} -> {:error, reason, sender}
    end
  end

  # The nonce is taken and none of ours has a receipt. The receipts are
  # asked for again at a later block before the keeper believes it, since a
  # node can answer one question from a newer block than the next.
  defp confirm_replaced(%{node: node} = sender, txs) do
    with {:ok, %{number: seen}} <- node.latest_block(),
         :ok <- later_block(sender, seen, @receipt_polls),
         {:ok, found} <- find_receipt(sender, txs) do
      case found do
        {tx, receipt} -> settled(sender, txs, tx, receipt)
        nil -> replaced_externally(sender, txs)
      end
    else
      {:error, reason} -> {:error, reason, sender}
    end
  end

  defp later_block(%{node: node} = sender, seen, polls_left) do
    case node.latest_block() do
      {:ok, %{number: number}} when number > seen ->
        :ok

      {:ok, _block} when polls_left > 1 ->
        Process.sleep(sender.receipt_poll_ms)
        later_block(sender, seen, polls_left - 1)

      {:ok, _block} ->
        {:error, :node_stalled}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replaced_externally(sender, [newest | _older] = txs) do
    sender =
      stop(
        %{sender | included_nonce: highest(sender.included_nonce, newest.nonce)},
        newest.job,
        :replaced_externally,
        "another transaction took nonce #{newest.nonce} from #{sender.wallet.address}, where the keeper sent #{newest.tx_hash}."
      )

    case settle_all(txs, %{status: :replaced_externally}) do
      :ok -> {:error, :stopped, sender}
      {:error, reason} -> {:error, reason, sender}
    end
  end

  # The node's latest nonce for the wallet. A node whose latest nonce is not
  # past one the keeper has already seen taken is behind, and is not asked
  # anything more until it catches up.
  defp latest_nonce(%{node: node, wallet: wallet, included_nonce: included}) do
    case node.nonce(wallet.address, :latest) do
      {:ok, latest} when is_integer(included) and latest <= included -> {:error, :node_behind}
      result -> result
    end
  end

  # With nothing waiting, the node's pending nonce passes its latest only when
  # something else is sending from the wallet.
  defp fresh_nonce(%{node: node, wallet: wallet} = sender) do
    with {:ok, latest} <- latest_nonce(sender),
         {:ok, pending} <- node.nonce(wallet.address, :pending) do
      if pending > latest,
        do:
          {:stop, :foreign_nonce,
           "#{wallet.address} has transactions pending from nonce #{latest} that the keeper did not send."},
        else: {:ok, latest}
    end
  end

  defp fees(%{node: node} = sender) do
    with {:ok, %{base_fee: base_fee}} <- node.latest_block(),
         {:ok, suggested} <- node.max_priority_fee() do
      priority = max(suggested, @min_priority_fee)
      max_fee = min(2 * base_fee + priority, sender.limits.max_fee)

      cond do
        base_fee > sender.limits.max_fee -> {:error, :base_fee_too_high}
        priority > max_fee -> {:error, :priority_fee_too_high}
        true -> {:ok, %{max_priority_fee: priority, max_fee: max_fee}}
      end
    end
  end

  # A reveal's estimate is low, because the coordinator's refusal is caught
  # inside the call, so it always gets at least 200,000 gas.
  defp gas_limit(%{node: node, wallet: wallet}, call) do
    with {:ok, data} <- Calls.calldata(call),
         {:ok, estimate} <- node.estimate_gas(wallet.address, call.target, data) do
      limit = div(estimate * 13 + 9, 10)
      {:ok, if(call.fn == :request_reveal, do: max(limit, @reveal_gas_floor), else: limit)}
    end
  end

  # What was spent in the last 24 hours, with each nonce still waiting at its
  # dearest, and this transaction at its most in place of any at its nonce.
  defp within_ceiling(sender, job, nonce, worst_case) do
    with {:ok, %{settled: settled, waiting: waiting}} <-
           Keeper.spend(sender.chain_id, sender.wallet.address) do
      total = settled + (waiting |> Map.put(nonce, worst_case) |> Map.values() |> Enum.sum())
      ceiling = sender.limits.daily_spend

      cond do
        total <= ceiling and sender.ceiling_reached? ->
          message = "spending over 24 hours back under #{Keeper.eth(ceiling)} ETH"
          Logger.info("Keeper sends again: its #{message}.")
          Keeper.record_pause(job, :unpaused_spend_ceiling, message)
          {:ok, %{sender | ceiling_reached?: false}}

        total <= ceiling ->
          {:ok, sender}

        sender.ceiling_reached? ->
          {:error, :spend_ceiling, sender}

        true ->
          message =
            "sending would take the keeper's spending over 24 hours to #{Keeper.eth(total)} ETH, past its #{Keeper.eth(ceiling)} ETH limit; it sends nothing until that falls."

          Logger.error("Keeper alert: " <> message)
          Keeper.record_pause(job, :paused_spend_ceiling, message)

          :telemetry.execute([:keyfleet, :keeper, :paused], %{count: 1}, %{
            job: job,
            reason: :spend_ceiling
          })

          {:error, :spend_ceiling, %{sender | ceiling_reached?: true}}
      end
    end
  end

  # Records the transaction, then gives it to the node.
  defp transmit(sender, %{call: call, fees: fees} = sending) do
    transaction =
      Map.merge(fees, %{
        chain_id: sender.chain_id,
        nonce: sending.nonce,
        gas_limit: sending.gas_limit
      })

    with {:ok, {raw, hash}} <- Wallet.sign(sender.wallet, call, transaction),
         {:ok, tx} <-
           transaction
           |> Map.merge(%{
             job: sending.job,
             fleet_id: sending.fleet_id,
             function: call.fn,
             target: call.target,
             from_address: sender.wallet.address,
             args: %{"arg" => call.arg},
             tx_hash: "0x" <> Base.encode16(hash, case: :lower),
             replaces_tx_hash: sending.replaces_tx_hash
           })
           |> Keeper.record_sent_tx(actor: %System{}),
         :ok <- hand_over(sender, tx, raw) do
      {:ok, tx}
    else
      {:error, {:send_failed, reason}} = failed ->
        Logger.error("Keeper alert: the node refused a keeper transaction: #{inspect(reason)}")
        failed

      other ->
        other
    end
  end

  # Gives a signed transaction to the node: `:ok` once it accepts it under
  # the hash the keeper recorded.
  defp hand_over(%{node: node}, tx, raw) do
    case node.send_raw(raw) do
      {:ok, hash} when hash == tx.tx_hash ->
        Logger.info(
          "Keeper sent #{tx.function} to #{tx.target} for #{tx.fleet_id} at nonce #{tx.nonce}: #{tx.tx_hash}"
        )

        :ok

      {:ok, hash} ->
        {:stop, :tx_hash_mismatch,
         "the node named #{hash} for the transaction the keeper signed as #{tx.tx_hash}."}

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  # Waits for a receipt for any transaction at the nonce, newest first, and
  # replaces the newest while replacements are left.
  defp await(sender, [newest | _older] = txs, replacements_left) do
    case poll(sender, txs, @receipt_polls) do
      {:ok, {tx, receipt}} -> settled(sender, txs, tx, receipt)
      {:ok, nil} when replacements_left > 0 -> replace(sender, txs, replacements_left)
      {:ok, nil} -> {:waiting, newest, sender}
      {:error, reason} -> {:error, reason, sender}
    end
  end

  defp poll(sender, txs, polls_left) do
    case find_receipt(sender, txs) do
      {:ok, nil} when polls_left > 1 ->
        Process.sleep(sender.receipt_poll_ms)
        poll(sender, txs, polls_left - 1)

      found ->
        found
    end
  end

  defp find_receipt(%{node: node}, txs) do
    Enum.reduce_while(txs, {:ok, nil}, fn tx, none ->
      case node.receipt(tx.tx_hash) do
        {:ok, nil} -> {:cont, none}
        {:ok, receipt} -> {:halt, possible(tx, receipt)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A receipt that could not be for what the keeper signed is the node
  # failing: more gas than the limit, a price above the maximum fee, or
  # numbers the record cannot hold.
  defp possible(tx, receipt) do
    if receipt.gas_used <= tx.gas_limit and receipt.effective_gas_price <= tx.max_fee and
         receipt.block_number <= @bigint and cost(receipt) <= @bigint do
      {:ok, {tx, receipt}}
    else
      Logger.error(
        "Keeper alert: the node gave #{tx.tx_hash} a receipt it cannot have: #{inspect(Map.delete(receipt, :logs))}; it stays waiting."
      )

      {:error, :impossible_receipt}
    end
  end

  # The same call at the same nonce with both fees a quarter higher, once the
  # call passes the checks again. Where the raise would pass the highest fee,
  # the newest is sent again as it is.
  defp replace(sender, [newest | _older] = txs, replacements_left) do
    fees = %{
      max_priority_fee: raise_fee(newest.max_priority_fee),
      max_fee: raise_fee(newest.max_fee)
    }

    case still_allowed(sender, newest) do
      {:ok, call} when fees.max_fee > sender.limits.max_fee ->
        resend(sender, txs, call)

      {:ok, call} ->
        raise_fees(sender, txs, call, fees, replacements_left)

      {:error, reason} ->
        Logger.warning(
          "Keeper left #{newest.tx_hash} waiting: its call did not pass the checks again: #{inspect(reason)}"
        )

        {:waiting, newest, sender}
    end
  end

  # The call is checked against the deployed fleets again.
  defp still_allowed(sender, tx) do
    with {:ok, call} <- Calls.new(tx.function, tx.target, tx.args["arg"]),
         {:ok, fleet} <- fleet(sender, tx.fleet_id),
         :ok <- allowed(fleet, call) do
      {:ok, call}
    end
  end

  defp raise_fees(sender, [newest | _older] = txs, call, fees, replacements_left) do
    with {:ok, sender} <-
           within_ceiling(sender, newest.job, newest.nonce, newest.gas_limit * fees.max_fee),
         {:ok, tx} <-
           transmit(sender, %{
             job: newest.job,
             fleet_id: newest.fleet_id,
             call: call,
             nonce: newest.nonce,
             fees: fees,
             gas_limit: newest.gas_limit,
             replaces_tx_hash: newest.tx_hash
           }) do
      await(sender, [tx | txs], replacements_left - 1)
    else
      {:stop, reason, message} -> {:error, :stopped, stop(sender, newest.job, reason, message)}
      {:error, reason} -> {:error, reason, sender}
      {:error, _reason, _sender} = refused -> refused
    end
  end

  # The newest transaction again, signed from its own record into the same
  # bytes, so nothing new is recorded. A node that already holds it, or has
  # included it, refuses it; the receipt decides.
  defp resend(sender, [newest | _older] = txs, call) do
    transaction = Map.take(newest, [:chain_id, :nonce, :max_priority_fee, :max_fee, :gas_limit])

    case Wallet.sign(sender.wallet, call, transaction) do
      {:ok, {raw, hash}} -> resent(same_bytes(newest, hash, raw, sender), sender, txs)
      {:error, reason} -> {:error, reason, sender}
    end
  end

  defp same_bytes(tx, hash, raw, sender) do
    if "0x" <> Base.encode16(hash, case: :lower) == tx.tx_hash,
      do: hand_over(sender, tx, raw),
      else:
        {:stop, :tx_hash_mismatch,
         "signing #{tx.tx_hash} again from its record gave other bytes, so it was not sent."}
  end

  defp resent(:ok, sender, txs), do: await(sender, txs, 0)

  defp resent({:error, {:send_failed, reason}}, sender, [newest | _older] = txs) do
    Logger.info(
      "Keeper sent #{newest.tx_hash} again at its highest fee; the node answered #{inspect(reason)}."
    )

    await(sender, txs, 0)
  end

  defp resent({:stop, reason, message}, sender, [newest | _older]),
    do: {:error, :stopped, stop(sender, newest.job, reason, message)}

  defp raise_fee(fee), do: div(fee * 5 + 3, 4)

  # The transaction the receipt is for takes it; the others at its nonce were
  # replaced.
  defp settled(sender, txs, %Transaction{} = included, receipt) do
    with :ok <- settle_all(Enum.reject(txs, &(&1.id == included.id)), %{status: :replaced}),
         {:ok, tx} <- settle(included, outcome(included, receipt)) do
      alert_outcome(tx)
      sender = %{sender | included_nonce: highest(sender.included_nonce, tx.nonce)}
      {:ok, tx, receipt, report(sender)}
    else
      {:error, reason} -> {:error, reason, sender}
    end
  end

  defp highest(nil, nonce), do: nonce
  defp highest(included, nonce), do: max(included, nonce)

  defp alert_outcome(%{status: :reverted} = tx) do
    Logger.error(
      "Keeper alert: #{tx.function} to #{tx.target} for #{tx.fleet_id} reverted in #{tx.tx_hash}."
    )
  end

  defp alert_outcome(%{result: "reveal_refused"} = tx) do
    Logger.error(
      "Keeper alert: the VRF coordinator refused #{tx.fleet_id}'s reveal of key #{tx.args["arg"]} in #{tx.tx_hash}; #{tx.fleet_id}'s reveals wait an hour."
    )
  end

  defp alert_outcome(_tx), do: :ok

  # A mined transaction's result is what its logs say beyond its status.
  defp outcome(tx, receipt) do
    %{
      status: if(receipt.status == 1, do: :mined, else: :reverted),
      block_number: receipt.block_number,
      gas_used: receipt.gas_used,
      effective_gas_price: receipt.effective_gas_price,
      cost_wei: cost(receipt),
      result:
        if(receipt.status == 1,
          do: Calls.result(tx.function, tx.target, tx.args["arg"], receipt.logs)
        )
    }
  end

  defp cost(receipt), do: receipt.gas_used * receipt.effective_gas_price

  defp settle_all(txs, outcome) do
    Enum.reduce_while(txs, :ok, fn tx, :ok ->
      case settle(tx, outcome) do
        {:ok, _tx} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp settle(tx, outcome) do
    with {:ok, tx} <- Keeper.settle(tx, outcome) do
      :telemetry.execute([:keyfleet, :keeper, :tx], %{count: 1}, %{
        function: tx.function,
        outcome: tx.status
      })

      {:ok, tx}
    end
  end

  # Stops sending and records the stop, so a restart stays stopped.
  defp stop(sender, job, reason, message) do
    Logger.error(
      "Keeper alert: #{message} The keeper has stopped sending; once the wallet is the keeper's alone, run bin/keeper-resume and restart the site."
    )

    case Keeper.record_stop(job, reason, message) do
      {:ok, _run} ->
        :ok

      {:error, error} ->
        Logger.error(
          "Keeper alert: the keeper could not record its stop, so a restart would send again: #{inspect(error)}"
        )
    end

    :telemetry.execute([:keyfleet, :keeper, :paused], %{count: 1}, %{job: job, reason: reason})
    %{sender | stopped: reason}
  end
end
