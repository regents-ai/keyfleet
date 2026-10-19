defmodule Keyfleet.Treasury.Upkeep do
  @moduledoc """
  Every five minutes (`config :keyfleet, Oban, cron:`): presses, from the
  upkeep account, the Treasury buttons anyone may press, as each comes due.
  For each deployed fleet:

    * the Daily Treasury Slice to Keys, once it may run, also when it would
      share nothing, so its next run stays a day ahead and an overdue slice
      always means one nobody has run;
    * the protocol share, whenever some is owed to REGENT staking;
    * each recorded proposal whose vote has closed and that can still be
      carried out, once it may be; one the vote rejected or someone
      cancelled is left alone.

  Then once, since the REGENT buyer serves every fleet in one line, Turn
  into REGENT, asking for 250 USDC and, while the buyer refuses that as
  moving the price more than 1%, half as much, down to 1 USDC.

  Each step is built by its button's own builder
  (`Keyfleet.WalletSteps.Build`), with the upkeep account as its signer, so
  a step its button can't press is skipped too. It is then simulated, and
  one the node refuses is skipped; so is one whose fee would be above 1 gwei
  per gas, or that the account hasn't the ETH to pay for. One transaction is
  sent at a time and waited for up to a minute; one that hasn't landed by
  then ends the run, and the next run settles it. Nothing is sent while an
  earlier transaction waits to land. None of these steps sends ETH: the
  account pays only their network fees. Sending is
  `Keyfleet.Treasury.Upkeep.Send`'s.

  What each run did with each step is a line (`Keyfleet.Treasury.UpkeepLine`)
  for the Treasury tab. What an admin has to act on is saved with the site's
  errors (`Keyfleet.Treasury.UpkeepError`), each kind its own error: too
  little ETH for a fee, a transaction that failed on the chain or never
  reached it, and an earlier one still waiting to land.

  Nothing runs, and nothing is recorded, without the upkeep key
  (KEYFLEET_UPKEEP_KEY), or while an admin has paused it
  (`Keyfleet.Treasury.UpkeepSwitch`). The switch is read again before every
  press, so a pause stops a run that is under way at its next step.
  """
  use Oban.Worker,
    queue: :upkeep,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Keyfleet.Actors.System
  alias Keyfleet.Fleets
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury
  alias Keyfleet.Treasury.Upkeep.Send
  alias Keyfleet.Treasury.UpkeepError
  alias Keyfleet.WalletSteps
  alias Keyfleet.WalletSteps.Build
  alias RegentChain.Call

  # The most a press offers to pay per gas, 1 gwei: far above what Base asks
  # of a quiet block, so a fee above it waits for a calmer run.
  @most_fee 1_000_000_000
  # Turn into REGENT asks first for a whole piece, as the buyer limits it,
  # and never for less than the least piece it takes, 1 USDC.
  @piece %{"amount" => "250"}
  @least_piece 1_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with operator when operator != nil <- Send.operator(),
         false <- Treasury.upkeep_paused?() do
      run_id = Ecto.UUID.generate()
      run(run_id, operator)
      Treasury.forget_upkeep_lines!(run_id)
    end

    :ok
  end

  defp run(run_id, operator) do
    with [first | _rest] = fleets <- Fleets.list_deployed_fleets!(),
         run = %{
           id: run_id,
           chain: WalletSteps.chain(first.chain_id),
           operator: operator,
           names: Map.new(fleets, &{&1.id, &1.name}),
           nonce: nil
         },
         {:ok, run} <- settle(run) do
      Enum.reduce_while(presses(fleets), run, &press/2)
    end
  end

  # Each fleet's steps in turn, then the one Turn into REGENT for them all.
  defp presses([first | _rest] = fleets) do
    Enum.flat_map(fleets, fn fleet ->
      [{fleet, :run_split, nil}, {fleet, :send_share, nil}] ++
        for proposal <- Proposals.awaiting_carry_out(fleet.id),
            do: {fleet, :carry_out, proposal.number}
    end) ++ [{first, :convert, nil}]
  end

  # Earlier lines still sent settle by their receipts. The account's count
  # of transactions is read first: when the node holds none of them waiting
  # then, a sent line with no receipt after it never reached the chain and
  # never will. While one waits, nothing more is sent.
  defp settle(run) do
    with {:ok, latest} <- Send.nonce(run.chain, run.operator, "latest"),
         {:ok, pending} <- Send.nonce(run.chain, run.operator, "pending") do
      waiting? = pending > latest
      Enum.each(Treasury.unsettled_upkeep_lines!(), &settle_line(run, &1, waiting?))

      if waiting? do
        UpkeepError.report(
          "An earlier transaction from the upkeep account #{run.operator} is still waiting " <>
            "to land, so the upkeep sent nothing this run. Its fee may be too low for the " <>
            "network now; if it keeps waiting, pause the upkeep and look at the account " <>
            "on Basescan."
        )

        record(run, %{outcome: :skipped, reason: :earlier_waiting})
      else
        {:ok, %{run | nonce: latest}}
      end
    else
      {:error, _reason} -> record(run, %{outcome: :skipped, reason: :unread})
    end
  end

  defp settle_line(run, line, waiting?) do
    case Send.landed(run.chain, line.transaction_hash) do
      {:ok, {:done, logs}} -> done(line, logs)
      {:ok, :reverted} -> reverted(run, line)
      {:ok, nil} when not waiting? -> not_sent(run, line, "it never reached the chain")
      _waiting_or_unread -> line
    end
  end

  defp press(press, run) do
    if Treasury.upkeep_paused?(), do: {:halt, run}, else: build(press, run)
  end

  defp build({fleet, flow, proposal}, run) do
    line = %{fleet_id: if(flow != :convert, do: fleet.id), step: flow, proposal: proposal}

    arguments = %{
      fleet_id: fleet.id,
      flow: flow,
      inputs: if(flow == :convert, do: @piece, else: %{}),
      proposal: proposal
    }

    {:ok, _request, built} = Build.build(arguments, run.operator)

    case due(flow, built) do
      {:press, step} -> transact(run, line, step, built.figures)
      {:skip, reason, opens_at} -> skip(run, line, reason, opens_at)
      :no_eth_for_gas -> no_eth(run, line)
      :leave -> {:cont, run}
    end
  end

  # Whether the one step the button builds is pressed now, and if not, why.
  # A chain that couldn't be read, or a proposal the site has not recorded
  # yet, waits for a later run.
  defp due(_flow, %{problem: problem}) when problem != nil, do: {:skip, :unread, nil}

  defp due(flow, %{steps: [step], figures: figures}) do
    case Map.fetch(figures.blocked, step.step) do
      {:ok, reason} -> blocked(flow, reason)
      :error -> {:press, step}
    end
  end

  defp blocked(_flow, :no_eth_for_gas), do: :no_eth_for_gas
  defp blocked(_flow, {:opens_at, at}), do: {:skip, :not_due, at}
  defp blocked(:carry_out, {:carry_out_from, at}), do: {:skip, :not_due, at}
  # Rejected, cancelled, expired or carried out already: it is left alone.
  defp blocked(:carry_out, _status), do: :leave

  defp blocked(_flow, reason) when reason in [:no_keys_sold, :nothing_owed, :nothing_queued],
    do: {:skip, reason, nil}

  defp transact(run, line, %{kind: "transaction", value: "0x0"} = step, figures) do
    with {:ok, step, estimate} <- simulate(run, line.step, step, figures),
         {:ok, fees} <- Send.fees(run.chain),
         :ok <- if(fees.max_fee > @most_fee, do: :fees_high, else: :ok),
         gas = Send.gas(estimate),
         {:ok, balance} <- Send.balance(run.chain, run.operator),
         :ok <- if(balance < gas * fees.max_fee, do: :no_eth_for_gas, else: :ok) do
      {:ok, signed} = Send.sign(run.chain, step, run.nonce, gas, fees)

      # Saved before it is broadcast, so a run that ends on the way still
      # leaves the transaction for the next one to settle.
      sent =
        record(
          run,
          Map.merge(line, %{
            outcome: :sent,
            transaction_hash: signed.hash,
            raw_transaction: signed.raw
          })
        )

      broadcast(run, sent, signed.raw)
    else
      :no_eth_for_gas -> no_eth(run, line)
      {:error, _reason} -> skip(run, line, :unread)
      reason when reason in [:refused, :fees_high] -> skip(run, line, reason)
    end
  end

  defp simulate(run, :convert, step, figures), do: convert(run, step, figures.amount)

  defp simulate(run, _flow, step, _figures) do
    case Send.estimate(run.chain, run.operator, step) do
      {:ok, estimate} -> {:ok, step, estimate}
      {:refused, _error} -> :refused
      {:error, reason} -> {:error, reason}
    end
  end

  # A piece the buyer refuses as moving the price is asked for again at
  # half, down to the least piece it takes.
  defp convert(run, step, amount) do
    piece = %{step | data: Call.encode("convert(uint256)", [amount])}

    case Send.estimate(run.chain, run.operator, piece) do
      {:ok, estimate} ->
        {:ok, piece, estimate}

      {:refused, error} ->
        if Send.price_moved?(error) and amount > @least_piece,
          do: convert(run, step, max(div(amount, 2), @least_piece)),
          else: :refused

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast(run, line, raw) do
    case Send.broadcast(run.chain, raw) do
      {:ok, _hash} ->
        landed(%{run | nonce: run.nonce + 1}, line)

      {:refused, error} ->
        not_sent(run, line, "the node refused it (#{inspect(error)})")
        {:cont, run}

      # It may have reached the node or not: the next run settles it.
      {:error, _unanswered} ->
        {:halt, run}
    end
  end

  defp landed(run, line) do
    case Send.await(run.chain, line.transaction_hash) do
      {:ok, {:done, logs}} ->
        done(line, logs)
        {:cont, run}

      {:ok, :reverted} ->
        reverted(run, line)
        {:cont, run}

      # Left sent for the next run to settle, and nothing more is sent now.
      :waiting ->
        {:halt, run}
    end
  end

  # A Turn into REGENT keeps the USDC its piece turned, from the buyer's
  # `RegentBought` in its receipt: the piece in line may be smaller than the
  # one asked for. A piece the buyer skipped turned none.
  defp done(%{step: :convert} = line, logs) do
    turned =
      case Send.regent_bought(logs) do
        {:ok, {_indexed, [usdc_in, _weth_mid, _regent_out]}} -> %{amount: usdc_in}
        :error -> %{}
      end

    Treasury.settle_upkeep_line!(line, :done, nil, turned, actor: %System{})
  end

  defp done(line, _logs), do: Treasury.settle_upkeep_line!(line, :done, nil, actor: %System{})

  defp skip(run, line, reason, opens_at \\ nil) do
    record(run, Map.merge(line, %{outcome: :skipped, reason: reason, opens_at: opens_at}))
    {:cont, run}
  end

  defp no_eth(run, line) do
    UpkeepError.report(
      "The upkeep account #{run.operator} has too little ETH on Base to pay the network fee " <>
        "for #{what(run, line)}. Send it some ETH; the next run presses it again."
    )

    skip(run, line, :no_eth_for_gas)
  end

  defp reverted(run, line) do
    UpkeepError.report(
      "The upkeep's transaction for #{what(run, line)} failed on the chain " <>
        "(#{line.transaction_hash}), spending its network fee. It is pressed again when it " <>
        "is next due; if it fails again, pause the upkeep and look at the transaction on " <>
        "Basescan."
    )

    Treasury.settle_upkeep_line!(line, :failed, :reverted, actor: %System{})
  end

  defp not_sent(run, line, why) do
    UpkeepError.report(
      "The upkeep's transaction for #{what(run, line)} was not sent: #{why}. Nothing was " <>
        "spent, and it is pressed again when it is next due."
    )

    Treasury.settle_upkeep_line!(line, :failed, :not_sent, actor: %System{})
  end

  defp what(run, %{step: :run_split, fleet_id: id}),
    do: "the Daily Treasury Slice to Keys of #{run.names[id]}"

  defp what(run, %{step: :send_share, fleet_id: id}),
    do: "sending the protocol share of #{run.names[id]}"

  defp what(run, %{step: :carry_out, fleet_id: id, proposal: number}),
    do: "carrying out proposal #{number} of #{run.names[id]}"

  defp what(_run, %{step: :convert}), do: "turning USDC from Key sales into REGENT"

  defp record(run, fields),
    do: Treasury.record_upkeep_line!(Map.put(fields, :run_id, run.id), actor: %System{})
end
