defmodule Keyfleet.Keeper.Income do
  @moduledoc """
  The keeper's income job, run five minutes after it starts and then every
  hour: it moves each fleet's launch income into the fleet, and sends the
  fleet's protocol share to the Regents staking contract once a day.

  For a fleet whose launch is still at auction as the fleet last recorded
  it, it opens a settle round (`Keyfleet.Keeper.Sender.settle_round/3`)
  and sends, in this order:

    * the strategy's `migrate` of the fleet's auction, once the auction
      may be settled and nobody has settled it yet, which gives the
      strategy its verdict, graduated or failed;
    * the fleet's `syncLaunch()`, once the strategy has its verdict, to
      record it; the next round goes on from the recorded state.

  For a fleet whose launch has graduated, and which has recorded that, it
  opens an income round (`Keyfleet.Keeper.Sender.income_round/3`) and
  sends, in this order and each only once the one before is included:

    * `release`, when the escrow has graduated and more of its subject
      tokens have vested than it has released;
    * `collect`, when collecting the LP position's fees now would bring
      any;
    * `sweep` of the USDC, the REGENT and the subject token, each the
      payment receiver holds any of;
    * `recognizeSurplusRevenue` of each of the three the splitter holds
      beyond what it owes;
    * `recognizeSurplus` of each of the three the fleet holds beyond what
      it has booked, once the fleet admits it.

  A call whose check finds nothing to do, or which the contract refuses,
  is passed over. A check the chain cannot answer ends that fleet's part of
  the round; the other fleets go on. A subject token the fleet does not
  admit yet waits as surplus, with a warning once a day.

  For every fleet, once 24 hours have passed since the keeper's own last
  `sendProtocolShare` for it was included, and none is still waiting, it
  sends one while the fleet owes any. Anyone may send it at any time; the
  keeper never looks for that and never waits on it.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.Keeper
  alias Keyfleet.Keeper.{Calls, Jobs, Sender}

  @day_seconds 86_400
  @vesting_seconds 365 * @day_seconds

  @doc false
  defstruct warned: %{}

  @doc "The job before its first round: nothing warned about."
  def new, do: %__MODULE__{}

  @doc "Runs one round, and returns the sender and the job for the next."
  def run(%Sender{} = sender, %__MODULE__{} = income) do
    started_at = DateTime.utc_now()

    {sender, income, tally} =
      sender
      |> Jobs.fleets()
      |> Enum.reduce_while({sender, income, %{sent: 0, skipped: 0}}, &fleet_round/2)

    if tally.sent > 0, do: Keeper.record_round(:income, started_at, tally)
    {sender, income}
  end

  # `{:next_fleet, acc}` ends the fleet's part of the round, and `{:halt,
  # acc}` the whole round.
  defp fleet_round(fleet, acc) do
    case launch_income(fleet, acc) do
      {:cont, acc} -> protocol_share(fleet, acc)
      {:next_fleet, acc} -> {:cont, acc}
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp launch_income(fleet, {sender, _income, _tally} = acc) do
    case Sender.read(sender, fleet.contract_address, :launch_state) do
      {:ok, :graduated} ->
        income_round(fleet, acc)

      {:ok, :auction_created} ->
        settle_round(fleet, acc)

      {:ok, _none_or_failed} ->
        {:cont, acc}

      {:error, reason} ->
        Logger.warning("Keeper could not read #{fleet.id}'s launch: #{inspect(reason)}")
        {:cont, acc}
    end
  end

  defp settle_round(fleet, acc),
    do: in_round(&Sender.settle_round/3, "settle", fleet, &settle_calls(fleet, &1), acc)

  defp income_round(fleet, acc),
    do: in_round(&Sender.income_round/3, "income", fleet, &income_calls(fleet, &1), acc)

  defp in_round(open, name, fleet, calls, {sender, income, tally}) do
    case open.(sender, fleet.id, fn sender, round ->
           {next, {sender, income, tally}} =
             round
             |> calls.()
             |> send_all(fleet, round, {sender, income, tally})

           {{next, income, tally}, sender}
         end) do
      {:ok, {next, income, tally}, sender} ->
        {next, {sender, income, tally}}

      # Their own alerts have said why.
      {:error, reason, sender} when reason in [:launch_mismatch, :treasury_mismatch] ->
        {:cont, {sender, income, tally}}

      {:error, reason, sender} ->
        Logger.warning("Keeper could not open #{fleet.id}'s #{name} round: #{inspect(reason)}")
        {:cont, {sender, income, tally}}
    end
  end

  defp settle_calls(fleet, round),
    do: [{:migrate, round.strategy, round.auction}, {:sync_launch, fleet.contract_address, nil}]

  defp income_calls(fleet, round) do
    [{:release, round.escrow, nil}, {:collect, round.locker, round.lp_token_id}] ++
      for(token <- round.tokens, do: {:sweep, round.receiver, token}) ++
      for(token <- round.tokens, do: {:recognize_surplus_revenue, round.splitter, token}) ++
      for(token <- round.tokens, do: {:recognize_surplus, fleet.contract_address, token})
  end

  defp send_all([call | calls], fleet, round, acc) do
    case send_due(fleet, round, call, acc) do
      {:cont, acc} -> send_all(calls, fleet, round, acc)
      ended -> ended
    end
  end

  defp send_all([], _fleet, _round, acc), do: {:cont, acc}

  defp send_due(fleet, round, {fun, target, arg}, {sender, income, tally}) do
    case due(sender, income, fleet, round, {fun, target, arg}) do
      {:ok, true, income} ->
        sender
        |> Jobs.send(:income, fleet, fun, target, arg)
        |> steer(income, tally)

      {:ok, false, income} ->
        {:cont, {sender, income, count(tally, :skipped)}}

      {:error, {:revert, _selector, _args} = reason} ->
        Logger.warning(
          "Keeper passed over #{fun} to #{target} for #{fleet.id}: its check was refused: #{inspect(reason)}"
        )

        {:cont, {sender, income, count(tally, :skipped)}}

      {:error, reason} ->
        Logger.warning(
          "Keeper passed over the rest of #{fleet.id}'s income round: it could not check #{fun} to #{target}: #{inspect(reason)}"
        )

        {:next_fleet, {sender, income, tally}}
    end
  end

  defp steer({:sent, _tx, sender}, income, tally),
    do: {:cont, {sender, income, count(tally, :sent)}}

  defp steer({:skipped, sender}, income, tally),
    do: {:cont, {sender, income, count(tally, :skipped)}}

  defp steer({:halt, sender}, income, tally), do: {:halt, {sender, income, tally}}

  # Whether a call would do anything now: `{:ok, due?, income}`, or
  # `{:error, reason}` when the chain could not say.
  defp due(sender, income, fleet, _round, {:migrate, _strategy, _auction}) do
    with {:ok, distribution} <- Sender.read(sender, fleet.contract_address, :launch_distribution),
         {:ok, block} <- sender.node.latest_block() do
      {:ok, distribution.lifecycle == :active and block.number >= distribution.migration_block,
       income}
    end
  end

  defp due(sender, income, _fleet, _round, {:sync_launch, fleet_address, nil}) do
    with {:ok, call} <- Calls.new(:sync_launch, fleet_address, nil),
         {:ok, state} <- Sender.dry_run(sender, call),
         do: {:ok, state != :auction_created, income}
  end

  defp due(sender, income, _fleet, round, {:release, escrow, nil}) do
    [_usdc, _regent, subject] = round.tokens

    with {:ok, :graduated} <- Sender.read(sender, escrow, :lifecycle),
         {:ok, held} <- Sender.read(sender, subject, :balance_of, [escrow]),
         {:ok, released} <- Sender.read(sender, escrow, :total_released),
         {:ok, start} <- Sender.read(sender, escrow, :vesting_start),
         {:ok, block} <- sender.node.latest_block() do
      {:ok, releasable(held, released, start, block.timestamp) > 0, income}
    else
      {:ok, _pending_or_failed} -> {:ok, false, income}
      {:error, reason} -> {:error, reason}
    end
  end

  defp due(sender, income, _fleet, _round, {:collect, locker, lp_token_id}) do
    with {:ok, call} <- Calls.new(:collect, locker, lp_token_id),
         {:ok, {amount0, amount1}} <- Sender.dry_run(sender, call),
         do: {:ok, amount0 > 0 or amount1 > 0, income}
  end

  defp due(sender, income, _fleet, _round, {:sweep, receiver, token}) do
    with {:ok, held} <- Sender.read(sender, token, :balance_of, [receiver]),
         do: {:ok, held > 0, income}
  end

  defp due(sender, income, _fleet, _round, {:recognize_surplus_revenue, splitter, token}) do
    with {:ok, held} <- Sender.read(sender, token, :balance_of, [splitter]),
         {:ok, owed} <- Sender.read(sender, splitter, :protected_balance, [token]),
         do: {:ok, held > owed, income}
  end

  defp due(sender, income, fleet, _round, {:recognize_surplus, fleet_address, token}) do
    with {:ok, surplus} when surplus > 0 <- Sender.read(sender, fleet_address, :surplus, [token]),
         {:ok, registry} <- Sender.read(sender, fleet_address, :asset_registry),
         {:ok, admitted?} <-
           Sender.read(sender, registry, :is_token_allowed, [fleet_address, token]) do
      {:ok, admitted?, if(admitted?, do: income, else: not_admitted(income, fleet, token))}
    else
      {:ok, 0} -> {:ok, false, income}
      {:error, reason} -> {:error, reason}
    end
  end

  # What `release` would send now: the vested share of everything the escrow
  # has held, less what it has released.
  defp releasable(held, released, start, now) do
    total = held + released
    elapsed = max(now - start, 0)

    vested =
      if elapsed >= @vesting_seconds, do: total, else: div(total * elapsed, @vesting_seconds)

    vested - released
  end

  defp not_admitted(income, fleet, token) do
    daily(income, {:not_admitted, fleet.id, token}, fn ->
      Logger.warning(
        "Keeper: #{fleet.id} holds #{token} it does not admit yet; it waits as surplus until the fleet admits it."
      )
    end)
  end

  # The keeper's own shares still waiting, or included in the last day, hold
  # the next back.
  defp protocol_share(fleet, {sender, income, tally} = acc) do
    since = DateTime.add(DateTime.utc_now(), -@day_seconds)

    with {:ok, []} <-
           Keeper.list_recent_txs(
             sender.chain_id,
             sender.wallet.address,
             fleet.id,
             :send_protocol_share,
             since,
             actor: %System{}
           ),
         {:ok, owed} when owed > 0 <-
           Sender.read(sender, fleet.contract_address, :protocol_share_owed) do
      sender
      |> Jobs.send(:income, fleet, :send_protocol_share, fleet.contract_address, nil)
      |> steer(income, tally)
    else
      {:ok, [_sent | _earlier]} ->
        {:cont, acc}

      {:ok, 0} ->
        {:cont, {sender, income, count(tally, :skipped)}}

      {:error, reason} ->
        Logger.warning("Keeper could not check #{fleet.id}'s protocol share: #{inspect(reason)}")

        {:cont, acc}
    end
  end

  defp count(tally, counted), do: Map.update!(tally, counted, &(&1 + 1))

  # Runs `warn` unless it ran for `key` in the last 24 hours.
  defp daily(income, key, warn) do
    now = DateTime.utc_now()
    last = Map.get(income.warned, key)

    if last && DateTime.diff(now, last) < @day_seconds do
      income
    else
      warn.()
      %{income | warned: Map.put(income.warned, key, now)}
    end
  end
end
