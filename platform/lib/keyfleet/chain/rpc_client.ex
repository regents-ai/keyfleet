defmodule KeyFleet.Chain.RpcClient do
  @moduledoc "`KeyFleet.Chain.Client` over JSON-RPC to the node at `KEYFLEET_RPC_URL`."
  @behaviour KeyFleet.Chain.Client

  require Logger

  alias KeyFleet.Chain.Abi

  @timeout 20_000

  @impl true
  def chain_id do
    with {:ok, result} <- request("eth_chainId", []) do
      case Abi.quantity(result) do
        {:ok, chain_id} -> {:ok, chain_id}
        :error -> {:error, :invalid_chain_id}
      end
    end
  end

  # Base's sequencer confirms `latest` in about two seconds; nothing here waits
  # for L1 finality.
  @impl true
  def head do
    with {:ok, header} <- block("latest"), do: head_of(header)
  end

  defp head_of(%{"number" => number, "hash" => hash, "timestamp" => timestamp}) do
    with {:ok, number} <- Abi.quantity(number),
         {:ok, seconds} <- Abi.quantity(timestamp),
         {:ok, timestamp} <- DateTime.from_unix(seconds) do
      {:ok, %{number: number, hash: hash, timestamp: timestamp}}
    else
      _malformed -> {:error, :invalid_block_header}
    end
  end

  defp head_of(_header), do: {:error, :invalid_block_header}

  @impl true
  def get_block_hash(block_number) do
    with {:ok, %{"hash" => hash}} <- block(hex_quantity(block_number)), do: {:ok, hash}
  end

  @impl true
  def get_logs(addresses, topic0s, from_block, to_block) do
    filter = %{
      address: addresses,
      topics: [topic0s],
      fromBlock: hex_quantity(from_block),
      toBlock: hex_quantity(to_block)
    }

    case request("eth_getLogs", [filter]) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_logs}
      {:error, reason} -> {:error, reason}
    end
  end

  # EIP-1898: the node answers at exactly that block, and refuses once it is
  # no longer on the chain.
  @impl true
  def call(to, data, block_hash) do
    call = %{to: to, data: "0x" <> Base.encode16(data, case: :lower)}

    case request("eth_call", [call, %{blockHash: block_hash, requireCanonical: true}]) do
      {:ok, result} ->
        case Abi.bytes(result) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_call_result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp block(tag) do
    case request("eth_getBlockByNumber", [tag, false]) do
      {:ok, %{"hash" => "0x" <> digits = hash} = header} when byte_size(digits) == 64 ->
        {:ok, %{header | "hash" => String.downcase(hash)}}

      {:ok, nil} ->
        {:error, :block_unavailable}

      {:ok, _header} ->
        {:error, :invalid_block_header}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, params) do
    case Req.post(Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:rpc_url],
           json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      # How nodes report a call the contract refused.
      {:ok, %{status: 200, body: %{"error" => %{"message" => "execution reverted" <> _reason}}}} ->
        {:error, :reverted}

      {:ok, %{status: status}} ->
        Logger.warning("chain read failed #{inspect(%{method: method, status: status})}")
        {:error, :chain_unavailable}

      {:error, reason} ->
        Logger.warning("chain read failed #{inspect(%{method: method, reason: reason})}")
        {:error, :chain_unavailable}
    end
  end

  defp hex_quantity(value), do: "0x" <> (value |> Integer.to_string(16) |> String.downcase())
end
