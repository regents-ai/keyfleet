defmodule Keyfleet.Keeper.Reveals do
  @moduledoc """
  The keeper's reveal job, run every 30 seconds: it asks a fleet's VRF
  coordinator again for keys that were sold but never got their seed.

  A round sends nothing while the base fee is above 2 gwei. It then takes
  each fleet on the keeper's chain whose key history was read recently,
  and passes over any that is not a consumer of its VRF subscription, or
  whose subscription holds under 0.02 ETH. Each of these holds is alerted
  when it begins and logged when it ends; a base fee or subscription hold
  is recorded as a pause too, and one still in force when the keeper
  starts goes on without being recorded or alerted again.

  For each fleet it looks at up to 25 keys with no recorded reveal, lowest
  first, leaving out any the keeper asked for in the last hour or is still
  waiting on, and reads each from the chain. A key with a seed is left for
  the chain reader to record. One never requested, or last requested an
  hour or more ago, is asked for again. Once the coordinator refuses one
  request, which the sender records and alerts, the fleet's reveals wait
  an hour from it. A key that cannot be read ends that fleet's part of the
  round; the other fleets go on.

  It reports each fleet's subscription balance, and how many of the keys
  it looked at have waited more than two minutes for a seed.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.{Chain, Keeper, Keys}
  alias Keyfleet.Keeper.{Jobs, Sender}

  @max_base_fee 2_000_000_000
  @min_vrf_balance 20_000_000_000_000_000
  @per_round 25
  @retry_after 3_600
  @waiting_after 120
  @no_seed "0x" <> String.duplicate("0", 64)

  @doc false
  defstruct holds: MapSet.new()

  @doc """
  The job before its first round, holding what the latest pause records
  say is still paused: the base fee, and each fleet's subscription balance.
  Returns `{:ok, reveals}` or `{:error, error}`.
  """
  def start(%Sender{} = sender) do
    gates = [:gas | Enum.map(Jobs.fleets(sender), &{:vrf_balance, &1.id})]

    Enum.reduce_while(gates, {:ok, %__MODULE__{}}, fn gate, {:ok, reveals} ->
      case pause_in_force(gate) do
        {:ok, true} -> {:cont, {:ok, %{reveals | holds: MapSet.put(reveals.holds, gate)}}}
        {:ok, false} -> {:cont, {:ok, reveals}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp pause_in_force(:gas), do: Keeper.pause_in_force(:gas)
  defp pause_in_force({:vrf_balance, fleet_id}), do: Keeper.pause_in_force(:vrf_balance, fleet_id)

  @doc "Runs one round, and returns the sender and the job for the next."
  def run(%Sender{} = sender, %__MODULE__{} = reveals) do
    started_at = DateTime.utc_now()

    case sender.node.latest_block() do
      {:ok, block} ->
        reveals = hold(reveals, :gas, block.base_fee > @max_base_fee, block)

        if :gas in reveals.holds,
          do: {sender, reveals},
          else: round(sender, reveals, block, started_at)

      {:error, reason} ->
        Logger.warning(
          "Keeper's reveal round could not read the latest block: #{inspect(reason)}"
        )

        {sender, reveals}
    end
  end

  defp round(sender, reveals, block, started_at) do
    {sender, reveals, tally} =
      sender
      |> Jobs.fleets()
      |> Enum.reduce_while({sender, reveals, %{sent: 0, skipped: 0}}, &fleet_round(&1, block, &2))

    if tally.sent > 0, do: Keeper.record_round(:reveal, started_at, tally)
    {sender, reveals}
  end

  defp fleet_round(fleet, block, {sender, reveals, tally}) do
    case open(sender, reveals, fleet) do
      {:open, reveals, asked} ->
        {next, sender, reveals, tally} = reveal_keys(sender, reveals, fleet, block, asked, tally)
        {next, {sender, reveals, tally}}

      {:closed, reveals} ->
        {:cont, {sender, reveals, tally}}
    end
  end

  # A fleet's keys may be asked for while its key history is fresh, it is a
  # consumer of a VRF subscription holding enough to pay, and the
  # coordinator has refused none of the keeper's requests in the last hour.
  # Returns what the keeper asked for recently with it.
  defp open(sender, reveals, fleet) do
    with {:ok, %{}} <- read(Chain.fresh_cursor(fleet.id), "its key history"),
         {:ok, subscription} <- read(subscription(sender, fleet), "its VRF subscription"),
         {:open, reveals} <- funded(reveals, fleet, subscription),
         {:ok, asked} <- read(asked(sender, fleet), "the keeper's recent requests for it") do
      refused = Enum.find(asked, &(&1.result == "reveal_refused"))
      reveals = hold(reveals, {:refused, fleet.id}, refused != nil, refused)
      if refused, do: {:closed, reveals}, else: {:open, reveals, asked}
    else
      {:ok, nil} ->
        {:closed, reveals}

      {:closed, reveals} ->
        {:closed, reveals}

      {:error, what, reason} ->
        Logger.warning(
          "Keeper passed over #{fleet.id}'s reveals: #{what} could not be read: #{inspect(reason)}"
        )

        {:closed, reveals}
    end
  end

  defp read({:error, reason}, what), do: {:error, what, reason}
  defp read(answer, _what), do: answer

  defp subscription(sender, fleet) do
    with {:ok, coordinator} <- Sender.read(sender, fleet.contract_address, :vrf_coordinator),
         {:ok, id} <- Sender.read(sender, fleet.contract_address, :vrf_subscription_id),
         {:ok, subscription} <- Sender.read(sender, coordinator, :get_subscription, [id]) do
      {:ok, Map.put(subscription, :id, id)}
    end
  end

  defp funded(reveals, fleet, subscription) do
    :telemetry.execute(
      [:keyfleet, :keeper, :vrf],
      %{native_balance_wei: subscription.native_balance},
      %{fleet: fleet.id}
    )

    reveals =
      reveals
      |> hold(
        {:not_consumer, fleet.id},
        fleet.contract_address not in subscription.consumers,
        subscription
      )
      |> hold(
        {:vrf_balance, fleet.id},
        subscription.native_balance < @min_vrf_balance,
        subscription
      )

    held? =
      {:not_consumer, fleet.id} in reveals.holds or {:vrf_balance, fleet.id} in reveals.holds

    {if(held?, do: :closed, else: :open), reveals}
  end

  # The keeper's requests for the fleet's keys it is still waiting on, or
  # that were included in the last hour.
  defp asked(sender, fleet) do
    Keeper.list_recent_txs(
      sender.chain_id,
      sender.wallet.address,
      fleet.id,
      :request_reveal,
      DateTime.add(DateTime.utc_now(), -@retry_after),
      actor: %System{}
    )
  end

  defp reveal_keys(sender, reveals, fleet, block, asked, tally) do
    with {:ok, minted} <- Sender.read(sender, fleet.contract_address, :total_minted),
         {:ok, token_ids} <-
           Keys.unrevealed(fleet.id, minted, Enum.map(asked, & &1.args["arg"]), @per_round) do
      reveal_keys(sender, reveals, fleet, block, token_ids, tally, 0)
    else
      {:error, reason} ->
        Logger.warning("Keeper could not find #{fleet.id}'s keys to reveal: #{inspect(reason)}")
        {:cont, sender, reveals, tally}
    end
  end

  defp reveal_keys(sender, reveals, fleet, block, [token_id | token_ids], tally, waiting) do
    case reveal_key(sender, fleet, block, token_id) do
      {:halt, sender} ->
        {:halt, sender, reveals, tally}

      {:unread, sender} ->
        {:cont, sender, reveals, tally}

      {:refused, tx, sender} ->
        reveals = hold(reveals, {:refused, fleet.id}, true, tx)
        {:cont, sender, reveals, count(tally, :sent)}

      {counted, sender, waited?} ->
        waiting = if waited?, do: waiting + 1, else: waiting
        reveal_keys(sender, reveals, fleet, block, token_ids, count(tally, counted), waiting)
    end
  end

  defp reveal_keys(sender, reveals, fleet, _block, [], tally, waiting) do
    :telemetry.execute([:keyfleet, :keeper, :reveals], %{waiting: waiting}, %{fleet: fleet.id})
    {:cont, sender, reveals, tally}
  end

  # The chain decides: a key with a seed is revealed, and one requested less
  # than an hour ago is still waiting for its answer. Returns whether it was
  # sent or passed over, and whether it has waited long for its seed.
  defp reveal_key(sender, fleet, block, token_id) do
    with {:ok, seed} <- Sender.read(sender, fleet.contract_address, :reveal_seed, [token_id]),
         {:ok, requested_at} <-
           Sender.read(sender, fleet.contract_address, :reveal_requested_at, [token_id]) do
      unseeded? = seed == @no_seed
      waited? = unseeded? and waited?(requested_at, block)

      if unseeded? and (requested_at == 0 or block.timestamp >= requested_at + @retry_after),
        do: request(sender, fleet, token_id, waited?),
        else: {:skipped, sender, waited?}
    else
      {:error, reason} ->
        Logger.warning(
          "Keeper passed over the rest of #{fleet.id}'s reveals this round: it could not read key #{token_id}: #{inspect(reason)}"
        )

        {:unread, sender}
    end
  end

  defp request(sender, fleet, token_id, waited?) do
    case Jobs.send(sender, :reveal, fleet, :request_reveal, fleet.contract_address, token_id) do
      {:sent, %{result: "reveal_refused"} = tx, sender} -> {:refused, tx, sender}
      {:sent, _tx, sender} -> {:sent, sender, waited?}
      {:skipped, sender} -> {:skipped, sender, waited?}
      {:halt, sender} -> {:halt, sender}
    end
  end

  defp waited?(0, _block), do: true
  defp waited?(requested_at, block), do: block.timestamp - requested_at > @waiting_after

  defp count(tally, counted), do: Map.update!(tally, counted, &(&1 + 1))

  # Notes a hold beginning or ending; nothing is said while it stays as it was.
  defp hold(reveals, gate, true = _holding?, detail) do
    if gate in reveals.holds do
      reveals
    else
      began(gate, detail)
      %{reveals | holds: MapSet.put(reveals.holds, gate)}
    end
  end

  defp hold(reveals, gate, false = _holding?, _detail) do
    if gate in reveals.holds do
      ended(gate)
      %{reveals | holds: MapSet.delete(reveals.holds, gate)}
    else
      reveals
    end
  end

  defp began(:gas, block) do
    pause(
      :paused_gas,
      :gas,
      "the base fee is #{gwei(block.base_fee)} gwei, above 2 gwei; reveals wait until it falls."
    )
  end

  defp began({:vrf_balance, fleet_id}, subscription) do
    pause(
      :paused_vrf_balance,
      :vrf_balance,
      "#{fleet_id}'s VRF subscription #{subscription.id} holds #{Keeper.eth(subscription.native_balance)} ETH, under 0.02 ETH; its reveals wait until the subscription is funded.",
      fleet_id
    )
  end

  # The sender alerted the refusal as it recorded it.
  defp began({:refused, fleet_id}, tx) do
    Logger.info(
      "Keeper holds #{fleet_id}'s reveals for an hour: the VRF coordinator refused key #{tx.args["arg"]} in #{tx.tx_hash}."
    )
  end

  defp began({:not_consumer, fleet_id}, subscription) do
    Logger.error(
      "Keeper alert: #{fleet_id} is not a consumer of its VRF subscription #{subscription.id}; its reveals wait until it is added."
    )

    paused(:not_consumer)
  end

  defp ended(:gas) do
    Logger.info("Keeper reveals go on: the base fee is back at or under 2 gwei.")
    Keeper.record_pause(:reveal, :unpaused_gas, "the base fee is back at or under 2 gwei")
  end

  defp ended({:vrf_balance, fleet_id}) do
    Logger.info(
      "Keeper reveals go on for #{fleet_id}: its VRF subscription holds 0.02 ETH or more."
    )

    Keeper.record_pause(
      :reveal,
      :unpaused_vrf_balance,
      "#{fleet_id}'s VRF subscription holds 0.02 ETH or more",
      fleet_id
    )
  end

  defp ended({:refused, fleet_id}) do
    Logger.info("Keeper reveals go on for #{fleet_id}: an hour has passed since the refusal.")
  end

  defp ended({:not_consumer, fleet_id}) do
    Logger.info("Keeper reveals go on for #{fleet_id}: it is a consumer of its VRF subscription.")
  end

  defp pause(outcome, reason, message, fleet_id \\ nil) do
    Logger.error("Keeper alert: " <> message)
    Keeper.record_pause(:reveal, outcome, message, fleet_id)
    paused(reason)
  end

  defp paused(reason),
    do:
      :telemetry.execute([:keyfleet, :keeper, :paused], %{count: 1}, %{
        job: :reveal,
        reason: reason
      })

  defp gwei(wei),
    do: wei |> Decimal.new() |> Decimal.div(1_000_000_000) |> Decimal.to_string(:normal)
end
