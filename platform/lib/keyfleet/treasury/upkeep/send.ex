defmodule Keyfleet.Treasury.Upkeep.Send do
  @moduledoc """
  How the upkeep account (`Keyfleet.Treasury.Upkeep`) sends one step, through
  the site's node for the chain (`Keyfleet.ChainClient`): simulated with
  `eth_estimateGas`, signed as an EIP-1559 transaction
  (`RegentChain.Transaction`), broadcast, and read back by its receipt. Each
  reader answers `{:ok, value}`, or `{:error, reason}` when the node didn't
  answer; the node refusing a step or a transaction is `{:refused, error}`,
  with the node's own error.

  The upkeep key is read here, from the application's settings, each time
  it signs, and goes nowhere else: never into a log, an error, a job or a
  record.
  """

  alias Keyfleet.ChainClient
  alias RegentChain.{Call, Event, Transaction}

  # The REGENT buyer's refusal of a piece that moves the route's price by
  # more than 1%.
  @price_moved Call.selector("PriceMoved(uint256)")
  @regent_bought_event "RegentBought(address,address,uint256,uint256,uint256)"
  @regent_bought Event.topic0(@regent_bought_event)
  # How often a sent transaction's receipt is read, and how many times
  # before the run leaves it to the next one: every 2 seconds for a minute.
  @poll_every 2_000
  @polls 30

  @doc "The upkeep account's lowercase address, or nil when no upkeep key is set."
  def operator do
    case private_key() do
      nil ->
        nil

      key ->
        {:ok, address} = Transaction.address(key)
        address
    end
  end

  @doc """
  How many transactions `account` has sent as of `tag`: `"latest"`, those
  that landed, or `"pending"`, with those the node holds waiting too.
  """
  def nonce(chain, account, tag),
    do: quantity(ChainClient.rpc(chain, "eth_getTransactionCount", [account, tag]))

  @doc "The ETH `account` holds at the latest block, in wei."
  def balance(chain, account),
    do: quantity(ChainClient.rpc(chain, "eth_getBalance", [account, "latest"]))

  @doc "The gas `step` takes sent from `account` now, as the node simulates it."
  def estimate(chain, account, step) do
    transaction = %{from: account, to: step.to, data: step.data, value: "0x0"}

    case ChainClient.rpc(chain, "eth_estimateGas", [transaction]) do
      {:error, {:rpc, error}} -> {:refused, error}
      answer -> quantity(answer)
    end
  end

  @doc "Whether the node refused a step as the REGENT buyer's `PriceMoved`."
  def price_moved?(%{"data" => "0x" <> _bytes = data}),
    do: String.starts_with?(String.downcase(data), @price_moved)

  def price_moved?(_error), do: false

  @doc "The gas a transaction is sent with: a fifth above the node's estimate."
  def gas(estimate), do: div(estimate * 6, 5)

  @doc """
  The fees per gas a transaction offers: `%{priority: tip, max_fee: most}`,
  the tip the node suggests, and at most twice the latest block's base fee
  and the tip, which still lands after the base fee has risen for a while.
  """
  def fees(chain) do
    with {:ok, priority} <- quantity(ChainClient.rpc(chain, "eth_maxPriorityFeePerGas", [])),
         {:ok, %{"baseFeePerGas" => base_fee}} <-
           ChainClient.rpc(chain, "eth_getBlockByNumber", ["latest", false]),
         {:ok, base_fee} <- quantity({:ok, base_fee}) do
      {:ok, %{priority: priority, max_fee: 2 * base_fee + priority}}
    else
      {:error, reason} -> {:error, reason}
      _unreadable -> {:error, :unreadable_answer}
    end
  end

  @doc """
  `step` signed with the upkeep key as the account's transaction `nonce`,
  with `gas` and `fees`, sending no ETH: `{:ok, %{raw: raw, hash: hash}}`.
  """
  def sign(chain, step, nonce, gas, fees) do
    Transaction.sign(
      %{
        chain_id: chain.chain_id,
        nonce: nonce,
        max_priority_fee_per_gas: fees.priority,
        max_fee_per_gas: fees.max_fee,
        gas: gas,
        to: step.to,
        value: 0,
        data: step.data
      },
      private_key()
    )
  end

  @doc "Hands the signed bytes to the node, which answers the transaction's hash."
  def broadcast(chain, raw) do
    case ChainClient.rpc(chain, "eth_sendRawTransaction", [raw]) do
      {:ok, hash} -> {:ok, hash}
      {:error, {:rpc, error}} -> {:refused, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  How the transaction `hash` ended: `{:ok, {:done, logs}}`, with its
  receipt's logs, `{:ok, :reverted}`, or `{:ok, nil}` while it has not landed.
  """
  def landed(chain, hash) do
    case ChainClient.receipt(chain, hash) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{"status" => "0x1", "logs" => logs}} -> {:ok, {:done, logs}}
      {:ok, %{"status" => "0x0"}} -> {:ok, :reverted}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  How the transaction `hash` ended, read every 2 seconds for up to a minute:
  as `landed/2` says, or `:waiting` when it has not landed by then.
  """
  def await(chain, hash) do
    Enum.reduce_while(1..@polls, :waiting, fn _poll, :waiting ->
      Process.sleep(@poll_every)

      case landed(chain, hash) do
        {:ok, ended} when ended != nil -> {:halt, {:ok, ended}}
        _not_yet -> {:cont, :waiting}
      end
    end)
  end

  @doc """
  The REGENT buyer's one `RegentBought` in a Turn into REGENT's receipt
  `logs`: `{:ok, {[payer, recipient], [usdc_in, weth_mid, regent_out]}}`, or
  `:error` when there is none, as when the buyer skipped a fleet whose piece
  couldn't be handed over. The transaction went to the buyer, so the log is
  the buyer's.
  """
  def regent_bought(logs) do
    case Enum.filter(logs, &bought?/1) do
      [%{"address" => buyer} = log] -> Event.one([log], @regent_bought_event, buyer, 2, 3)
      _absent_or_duplicated -> :error
    end
  end

  defp bought?(%{"topics" => [topic | _indexed]}) when is_binary(topic),
    do: String.downcase(topic) == @regent_bought

  defp bought?(_log), do: false

  defp private_key do
    :keyfleet
    |> Application.get_env(Keyfleet.Treasury.Upkeep, [])
    |> Keyword.get(:private_key)
  end

  defp quantity({:ok, "0x" <> hex}) do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _unreadable -> {:error, :unreadable_answer}
    end
  end

  defp quantity({:ok, _unreadable}), do: {:error, :unreadable_answer}
  defp quantity({:error, reason}), do: {:error, reason}
end
