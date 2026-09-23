defmodule KeyFleet.Chain.TreasuryReader do
  @moduledoc """
  Reads one deployed fleet's balances at the block the node last called its
  head, and keeps them as the fleet's `KeyFleet.Treasury.Reading`.
  `KeyFleet.Chain.Repeat` runs it once a minute.

  Every figure of a reading comes from that one block: for each asset
  `KeyFleet.Treasury.budget_assets/2` lists, the budget, the reward backing
  and the pay period, beside the Cascade reserve, the protocol share owed and
  whether the launch has settled. An asset read for the first time also has
  its symbol and decimals read and kept, once; a token that does not answer
  one of them, by reverting or with something else, has it kept as unknown.
  A reading that fails in any part keeps nothing and is tried again at the
  next one. A reading of a later block than the one kept replaces it and is
  announced as `{:balances_changed, fleet_id}` on `KeyFleet.Proposals.topic/1`.
  """

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain.Abi
  alias KeyFleet.Proposals
  alias KeyFleet.Treasury

  # cast sig of each view function read.
  @reward_assets <<0x88, 0x0E, 0xC0, 0x4E>>
  @free_capital <<0x2B, 0x84, 0x30, 0x8E>>
  @pay_period <<0xE6, 0xEC, 0x9E, 0x56>>
  @backed <<0x59, 0x5B, 0x7F, 0x21>>
  @cascade_reserve <<0xFC, 0x4E, 0x89, 0x64>>
  @protocol_share_owed <<0xC4, 0x90, 0xB9, 0xC7>>
  @launch_settled <<0x06, 0xE9, 0x3D, 0xAE>>
  @decimals <<0x31, 0x3C, 0xE5, 0x67>>
  @symbol <<0x95, 0xD8, 0x9B, 0x41>>
  @system %System{}

  @doc "Reads the fleet's balances at the node's head and keeps them."
  def read(fleet, client) do
    with {:ok, head} <- client.head(),
         at = &call(client, &1, &2, head.hash),
         {:ok, [rewards]} <- at.(fleet.rewards_address, {@reward_assets, [{:array, :address}]}),
         assets = Treasury.budget_assets(fleet, rewards),
         :ok <- read_details(fleet, assets, client, head.hash),
         {:ok, balances} <- balances(fleet, assets, at),
         {:ok, [reserve]} <- at.(fleet.contract_address, {@cascade_reserve, [{:uint, 256}]}),
         {:ok, [owed]} <- at.(fleet.contract_address, {@protocol_share_owed, [{:uint, 256}]}),
         {:ok, [settled]} <- at.(fleet.contract_address, {@launch_settled, [:bool]}),
         {:ok, reading} <-
           Treasury.record_reading(
             %{
               fleet_id: fleet.id,
               block_number: head.number,
               block_hash: head.hash,
               block_time: head.timestamp,
               launch_settled: settled,
               cascade_reserve: Decimal.new(reserve),
               protocol_share_owed: Decimal.new(owed),
               assets: balances
             },
             actor: @system
           ) do
      announce(fleet, reading)
      {:ok, reading}
    end
  end

  defp announce(fleet, reading) do
    unless Ash.Resource.get_metadata(reading, :upsert_skipped) do
      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        Proposals.topic(fleet.id),
        {:balances_changed, fleet.id}
      )
    end
  end

  # The symbol and decimals of each asset read for the first time.
  defp read_details(fleet, assets, client, block_hash) do
    known = MapSet.new(Treasury.asset_details!(fleet.id, actor: @system), & &1.asset)

    assets
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.reduce_while(:ok, fn asset, :ok ->
      with {:ok, symbol} <- detail(client, asset, {@symbol, :bytes}, block_hash),
           {:ok, decimals} <- detail(client, asset, {@decimals, {:uint, 8}}, block_hash),
           {:ok, _details} <-
             Treasury.record_asset_details(
               %{fleet_id: fleet.id, asset: asset, symbol: symbol, decimals: decimals},
               actor: @system
             ) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end

  # A token that reverts, or answers with something else, does not answer.
  defp detail(client, asset, {data, type}, block_hash) do
    case client.call(asset, data, block_hash) do
      {:ok, returned} -> {:ok, answer(Abi.decode(returned, [type]))}
      {:error, :reverted} -> {:ok, nil}
      {:error, reason} -> {:error, {asset, reason}}
    end
  end

  defp answer({:ok, [symbol]}) when is_binary(symbol), do: String.replace_invalid(symbol)
  defp answer({:ok, [decimals]}), do: decimals
  defp answer(:error), do: nil

  defp balances(fleet, assets, at) do
    assets
    |> Enum.reduce_while({:ok, []}, fn asset, {:ok, balances} ->
      case balance(fleet, asset, at) do
        {:ok, balance} -> {:cont, {:ok, [balance | balances]}}
        failure -> {:halt, failure}
      end
    end)
    |> then(fn
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      failure -> failure
    end)
  end

  defp balance(fleet, asset, at) do
    word = address_word(asset)

    with {:ok, [free]} <- at.(fleet.contract_address, {@free_capital <> word, [{:uint, 256}]}),
         {:ok, [start, cap, spent]} <-
           at.(
             fleet.contract_address,
             {@pay_period <> word, [{:uint, 64}, {:uint, 256}, {:uint, 256}]}
           ),
         {:ok, [backed]} <- at.(fleet.rewards_address, {@backed <> word, [{:uint, 256}]}),
         {:ok, start} <- period_start(start) do
      {:ok,
       %{
         asset: asset,
         free_capital: free,
         backed: backed,
         pay_period_start: start,
         pay_cap: cap,
         pay_spent: spent
       }}
    end
  end

  # A period's start is zero before the asset's first payment.
  defp period_start(0), do: {:ok, nil}
  defp period_start(seconds), do: DateTime.from_unix(seconds)

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

  defp address_word("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :lower)
end
