defmodule Keyfleet.Chain.RewardsWaiting do
  @moduledoc """
  The USDC one key has earned and not yet had paid out: what the fleet's
  `KeyfleetRewards.accrued(usdc, tokenId)` answers at the block the node
  last called its head.

  An answer is kept for 30 seconds in a table this process owns, so a key
  opened again and again in that time is read from the chain once. A read
  that fails keeps nothing, and the next one asks again.
  """
  use GenServer

  alias RegentChain.Abi
  alias RegentChain.Call

  @table __MODULE__
  @kept_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  The atomic USDC waiting for key `token_id` of `fleet`, which names its
  `fleet_id`, `rewards_address` and `usdc_address`, as `{:ok, amount}`, or
  the chain's `{:error, reason}`. An answer read less than 30 seconds before
  `now`, in monotonic milliseconds, is given again without asking the chain.
  """
  def read(fleet, token_id, client, now \\ System.monotonic_time(:millisecond)) do
    key = {fleet.fleet_id, token_id}

    case :ets.lookup(@table, key) do
      [{^key, amount, read_at}] when now - read_at < @kept_ms -> {:ok, amount}
      _unread_or_old -> read_chain(fleet, token_id, client, key, now)
    end
  end

  defp read_chain(fleet, token_id, client, key, now) do
    data = Call.encode("accrued(address,uint256)", [fleet.usdc_address, token_id])

    with {:ok, head} <- client.head(),
         {:ok, returned} <- client.call(fleet.rewards_address, data, head.hash),
         {:ok, [amount]} <- decode(returned) do
      :ets.insert(@table, {key, amount, now})
      {:ok, amount}
    end
  end

  defp decode(returned) do
    case Abi.decode(returned, [{:uint, 256}]) do
      {:ok, values} -> {:ok, values}
      :error -> {:error, :unreadable_answer}
    end
  end
end
