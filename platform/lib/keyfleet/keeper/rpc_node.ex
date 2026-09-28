defmodule Keyfleet.Keeper.RpcNode do
  @moduledoc "`Keyfleet.Keeper.Node` over JSON-RPC to the node at `KEYFLEET_RPC_URL`."
  @behaviour Keyfleet.Keeper.Node

  require Logger

  alias Keyfleet.Chain.JsonRpc
  alias RegentChain.Abi

  @impl true
  def chain_id, do: quantity("eth_chainId", [])

  @impl true
  def latest_block do
    case request("eth_getBlockByNumber", ["latest", false]) do
      {:ok, %{"number" => number, "timestamp" => timestamp, "baseFeePerGas" => base_fee}} ->
        with {:ok, number} <- Abi.quantity(number),
             {:ok, timestamp} <- Abi.quantity(timestamp),
             {:ok, base_fee} <- Abi.quantity(base_fee) do
          {:ok, %{number: number, timestamp: timestamp, base_fee: base_fee}}
        else
          :error -> {:error, :invalid_block_header}
        end

      {:ok, _header} ->
        {:error, :invalid_block_header}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def call(from, to, data) do
    with {:ok, result} <- request("eth_call", [transaction(from, to, data), "latest"]) do
      case Abi.bytes(result) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :invalid_call_result}
      end
    end
  end

  @impl true
  def estimate_gas(from, to, data),
    do: quantity("eth_estimateGas", [transaction(from, to, data)])

  @impl true
  def balance(address), do: quantity("eth_getBalance", [address, "latest"])

  @impl true
  def nonce(address, tag) when tag in [:latest, :pending],
    do: quantity("eth_getTransactionCount", [address, Atom.to_string(tag)])

  @impl true
  def max_priority_fee, do: quantity("eth_maxPriorityFeePerGas", [])

  @impl true
  def send_raw(raw) do
    with {:ok, hash} <- request("eth_sendRawTransaction", [hex(raw)]) do
      case Abi.hash(hash) do
        {:ok, hash} -> {:ok, hash}
        :error -> {:error, :invalid_tx_hash}
      end
    end
  end

  @impl true
  def receipt(tx_hash) do
    case request("eth_getTransactionReceipt", [tx_hash]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{} = receipt} -> receipt_of(receipt)
      {:ok, _other} -> {:error, :invalid_receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receipt_of(
         %{
           "status" => status,
           "blockNumber" => block_number,
           "gasUsed" => gas_used,
           "effectiveGasPrice" => effective_gas_price,
           "logs" => logs
         } = receipt
       )
       when is_list(logs) do
    with {:ok, status} when status in [0, 1] <- Abi.quantity(status),
         {:ok, block_number} <- Abi.quantity(block_number),
         {:ok, gas_used} <- Abi.quantity(gas_used),
         {:ok, effective_gas_price} <- Abi.quantity(effective_gas_price),
         {:ok, l1_fee} <- l1_fee(receipt) do
      {:ok,
       %{
         status: status,
         block_number: block_number,
         gas_used: gas_used,
         effective_gas_price: effective_gas_price,
         l1_fee: l1_fee,
         logs: logs
       }}
    else
      _malformed -> {:error, :invalid_receipt}
    end
  end

  defp receipt_of(_receipt), do: {:error, :invalid_receipt}

  # Base's receipts carry the L1 data fee; a chain without one has none.
  defp l1_fee(%{"l1Fee" => l1_fee}), do: Abi.quantity(l1_fee)
  defp l1_fee(_receipt), do: {:ok, nil}

  defp quantity(method, params) do
    with {:ok, result} <- request(method, params) do
      case Abi.quantity(result) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :invalid_quantity}
      end
    end
  end

  defp request(method, params) do
    case JsonRpc.request(method, params) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:rpc_error, error}} ->
        {:error, revert_or_error(error)}

      {:error, {:unavailable, detail}} ->
        Logger.warning("Keeper node request failed #{inspect(Map.put(detail, :method, method))}")
        {:error, :chain_unavailable}
    end
  end

  # A refusal carries the contract's error as hex data, or no data for a bare
  # `revert()`; data that is not hex is the node failing, not the contract.
  defp revert_or_error(error) do
    with true <- JsonRpc.reverted?(error),
         {:ok, bytes} <- revert_data(error.data) do
      case bytes do
        <<selector::binary-size(4), args::binary>> -> {:revert, selector, args}
        bytes -> {:revert, nil, bytes}
      end
    else
      _node_error -> {:rpc_error, error}
    end
  end

  defp revert_data(nil), do: {:ok, <<>>}
  defp revert_data(data), do: Abi.bytes(data)

  defp transaction(from, to, data), do: %{from: from, to: to, data: hex(data)}

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
