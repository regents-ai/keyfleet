defmodule Keyfleet.Chain.TreasuryReader do
  @moduledoc """
  Reads one deployed fleet's money at the block the node last called its
  head, and keeps it as the fleet's `Keyfleet.Treasury.Reading`.
  `Keyfleet.Chain.ReadBalances` runs it every minute.

  A reading covers each asset the treasury's daily split shares
  (`splitAssets()`: ETH, REGENT, USDC, then OUSD once admitted and the launch
  token once bound) and no other: a token merely sent to the treasury is
  never read or shown. Every figure of a reading comes from that one block:
  for each of those assets, what the treasury holds and what the reward
  ledger backs, beside the split's rate, when it last ran and when anyone
  may next run it, the launch token, the Cascade reserve and the protocol
  share owed to REGENT staking. A reading that fails in any part keeps
  nothing and is tried again at the next one. A reading of a later block
  than the one kept replaces it and is announced as `{:balances_changed,
  fleet_id}` on `Keyfleet.Proposals.topic/1`.

  Once a reading is kept, the symbol and decimals of each of its tokens not
  yet known in full are read at the same block; ETH and the fleet's USDC are
  known already. A token that refuses a call, answers with something else,
  or reports a symbol that is not 1 to 32 bytes of text free of control and
  direction characters, has it kept as unknown and is asked again at every
  reading, as is one whose call failed, with a warning, since the node may
  have failed.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury
  alias RegentChain.Abi
  alias RegentChain.Call

  # The calldata of each view read without an argument.
  @split_assets Call.encode("splitAssets()", [])
  @daily_split_bps Call.encode("dailySplitBps()", [])
  @last_run_at Call.encode("lastRunAt()", [])
  @next_run_at Call.encode("nextRunAt()", [])
  @launch_token Call.encode("launchToken()", [])
  @cascade_reserve Call.encode("cascadeReserve()", [])
  @protocol_share_owed Call.encode("protocolShareOwed()", [])
  @decimals Call.encode("decimals()", [])
  @symbol Call.encode("symbol()", [])
  @system %System{}

  @doc "Reads the fleet's money at the node's head and keeps it, then any unread token details."
  def read(fleet, client) do
    with {:ok, head} <- client.head(),
         {:ok, reading} <- read_money(fleet, client, head) do
      read_details(fleet, reading, client, head.hash)
      {:ok, reading}
    end
  end

  defp read_money(fleet, client, head) do
    at = &call(client, &1, &2, head.hash)
    treasury = fleet.treasury_address

    with {:ok, [assets]} <- at.(treasury, {@split_assets, [{:array, :address}]}),
         {:ok, balances} <- balances(fleet, assets, client, at, head),
         {:ok, [bps]} <- at.(treasury, {@daily_split_bps, [{:uint, 16}]}),
         {:ok, [last_run_at]} <- at.(treasury, {@last_run_at, [{:uint, 63}]}),
         {:ok, [next_run_at]} <- at.(treasury, {@next_run_at, [{:uint, 63}]}),
         {:ok, [launch_token]} <- at.(treasury, {@launch_token, [:address]}),
         {:ok, [reserve]} <- at.(fleet.contract_address, {@cascade_reserve, [{:uint, 256}]}),
         {:ok, [owed]} <- at.(fleet.contract_address, {@protocol_share_owed, [{:uint, 256}]}),
         {:ok, reading} <-
           Treasury.record_reading(
             %{
               fleet_id: fleet.id,
               block_number: head.number,
               block_hash: head.hash,
               block_time: head.timestamp,
               cascade_reserve: Decimal.new(reserve),
               protocol_share_owed: Decimal.new(owed),
               daily_split_bps: bps,
               last_run_at: time(last_run_at),
               next_run_at: time(next_run_at),
               launch_token: if(launch_token != Treasury.native(), do: launch_token),
               assets: balances
             },
             actor: @system
           ) do
      announce(fleet, reading)
      {:ok, reading}
    end
  end

  # The contracts say zero for a time that has not come about yet.
  defp time(0), do: nil
  defp time(seconds), do: DateTime.from_unix!(seconds)

  defp announce(fleet, reading) do
    unless Ash.Resource.get_metadata(reading, :upsert_skipped) do
      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Proposals.topic(fleet.id),
        {:balances_changed, fleet.id}
      )
    end
  end

  # The symbol and decimals of the reading's tokens not yet read in full.
  defp read_details(fleet, reading, client, block_hash) do
    known = Map.new(Treasury.asset_details!(fleet.id, actor: @system), &{&1.asset, &1})

    reading.assets
    |> Enum.map(& &1.asset)
    |> Enum.reject(&(&1 in [Treasury.native(), fleet.usdc_address] or complete?(known[&1])))
    |> Enum.each(&read_token(fleet, &1, client, block_hash))
  end

  defp complete?(%{symbol: symbol, decimals: decimals}), do: symbol != nil and decimals != nil
  defp complete?(nil), do: false

  # A call that fails may be the node's, so nothing is kept, and the token
  # is asked again at the next reading.
  defp read_token(fleet, asset, client, block_hash) do
    with {:ok, symbol} <- detail(client, asset, {@symbol, :bytes}, block_hash),
         {:ok, decimals} <- detail(client, asset, {@decimals, {:uint, 8}}, block_hash) do
      record_details(fleet, asset, symbol, decimals)
    else
      {:error, reason} ->
        Logger.warning(
          "Fleet #{fleet.id}: token #{asset} was not read " <>
            "(#{inspect(reason)}); it is asked again at the next reading."
        )
    end
  end

  defp record_details(fleet, asset, symbol, decimals) do
    Treasury.record_asset_details!(
      %{fleet_id: fleet.id, asset: asset, symbol: symbol, decimals: decimals},
      actor: @system
    )
  end

  # A token that refuses, or answers with something else, does not answer.
  defp detail(client, asset, {data, type}, block_hash) do
    case client.call(asset, data, block_hash) do
      {:ok, returned} -> {:ok, answer(Abi.decode(returned, [type]))}
      {:error, :reverted} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer({:ok, [symbol]}) when is_binary(symbol), do: if(symbol?(symbol), do: symbol)
  defp answer({:ok, [decimals]}), do: decimals
  defp answer(:error), do: nil

  # A symbol is shown as written, so only short plain text is taken as one.
  defp symbol?(symbol) do
    byte_size(symbol) in 1..32 and String.valid?(symbol) and
      not (symbol |> String.to_charlist() |> Enum.any?(&hidden?/1))
  end

  # Control characters, the zero byte among them, and the characters that
  # turn text around.
  defp hidden?(char) when char < 0x20 or char in 0x7F..0x9F, do: true
  defp hidden?(char) when char in [0x061C, 0x200E, 0x200F], do: true
  defp hidden?(char) when char in 0x202A..0x202E or char in 0x2066..0x2069, do: true
  defp hidden?(_char), do: false

  defp balances(fleet, assets, client, at, head) do
    assets
    |> Enum.reduce_while({:ok, []}, fn asset, {:ok, balances} ->
      case balance(fleet, asset, client, at, head) do
        {:ok, balance} -> {:cont, {:ok, [balance | balances]}}
        failure -> {:halt, failure}
      end
    end)
    |> then(fn
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      failure -> failure
    end)
  end

  defp balance(fleet, asset, client, at, head) do
    backed = Call.encode("backed(address)", [asset])

    with {:ok, held} <- held(fleet, asset, client, at, head),
         {:ok, [backed]} <- at.(fleet.rewards_address, {backed, [{:uint, 256}]}) do
      {:ok, %{asset: asset, held: held, backed: backed}}
    end
  end

  defp held(fleet, asset, client, at, head) do
    if asset == Treasury.native() do
      case client.get_balance(fleet.treasury_address, head.hash) do
        {:ok, wei} -> {:ok, wei}
        {:error, reason} -> {:error, {fleet.treasury_address, reason}}
      end
    else
      balance_of = Call.encode("balanceOf(address)", [fleet.treasury_address])
      with {:ok, [held]} <- at.(asset, {balance_of, [{:uint, 256}]}), do: {:ok, held}
    end
  end

  defp call(client, to, {data, types}, block_hash) do
    with {:ok, returned} <- client.call(to, data, block_hash),
         {:ok, values} <- decode(returned, types) do
      {:ok, values}
    else
      {:error, reason} -> {:error, {to, reason}}
    end
  end

  defp decode(returned, types) do
    case Abi.decode(returned, types) do
      {:ok, values} -> {:ok, values}
      :error -> {:error, :unreadable_answer}
    end
  end
end
