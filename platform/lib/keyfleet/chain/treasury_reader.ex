defmodule KeyFleet.Chain.TreasuryReader do
  @moduledoc """
  Reads one deployed fleet's balances once a minute, at the block the node
  last called its head, and keeps them as the fleet's `KeyFleet.Treasury.Reading`.

  Every figure of a reading comes from that one block: the reward ledger's
  assets, and for each its symbol, decimals, budget, reward backing and pay
  period, beside the Cascade reserve, the protocol share owed and whether the
  launch has settled. A reading that fails in any part keeps nothing, is
  logged, and is tried again a minute later. A kept reading is announced
  where the fleet's proposal pages listen.
  """
  use GenServer

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain.Abi
  alias KeyFleet.Chain.Client
  alias KeyFleet.Proposals
  alias KeyFleet.Treasury

  @every 60_000

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

  def child_spec(fleet),
    do: %{id: {__MODULE__, fleet.id}, start: {__MODULE__, :start_link, [fleet]}}

  def start_link(fleet), do: GenServer.start_link(__MODULE__, fleet)

  @impl true
  def init(fleet) do
    send(self(), :read)
    {:ok, %{fleet: fleet, client: Client.configured()}}
  end

  @impl true
  def handle_info(:read, %{fleet: fleet, client: client} = state) do
    case read(fleet, client) do
      {:ok, _reading} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Fleet #{fleet.id}: balances were not read (#{inspect(reason)}); trying again in a minute."
        )
    end

    Process.send_after(self(), :read, @every)
    {:noreply, state}
  end

  @doc "Reads the fleet's balances at the node's head and keeps them."
  def read(fleet, client) do
    with {:ok, head} <- client.head(),
         at = &call(client, &1, &2, head.hash),
         {:ok, [assets]} <- at.(fleet.rewards_address, {@reward_assets, [{:array, :address}]}),
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
             actor: %System{}
           ) do
      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        Proposals.topic(fleet.id),
        {:proposals_changed, fleet.id}
      )

      {:ok, reading}
    end
  end

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

    with {:ok, [symbol]} <- at.(asset, {@symbol, [:bytes]}),
         {:ok, [decimals]} <- at.(asset, {@decimals, [{:uint, 8}]}),
         {:ok, [free]} <- at.(fleet.contract_address, {@free_capital <> word, [{:uint, 256}]}),
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
         symbol: String.replace_invalid(symbol),
         decimals: decimals,
         free_capital: Decimal.new(free),
         backed: Decimal.new(backed),
         pay_period_start: start,
         pay_cap: Decimal.new(cap),
         pay_spent: Decimal.new(spent)
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
