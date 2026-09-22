defmodule KeyFleet.Chain.RpcClient do
  @moduledoc "`KeyFleet.Chain.Client` over JSON-RPC to the node at `KEYFLEET_RPC_URL`."
  @behaviour KeyFleet.Chain.Client

  require Logger

  @timeout 20_000

  @impl true
  def chain_id do
    with {:ok, result} <- request("eth_chainId", []), do: quantity(result)
  end

  # Base's sequencer confirms `latest` in about two seconds; nothing here waits
  # for L1 finality.
  @impl true
  def head do
    case block("latest") do
      {:ok, %{"number" => number, "hash" => hash}} ->
        with {:ok, number} <- quantity(number), do: {:ok, %{number: number, hash: hash}}

      {:ok, _header} ->
        {:error, :invalid_block_header}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_block_hash(block_number) do
    with {:ok, %{"hash" => hash}} <- block(hex_quantity(block_number)), do: {:ok, hash}
  end

  @impl true
  def get_logs(address, topic0, from_block, to_block) do
    filter = %{
      address: address,
      topics: [topic0],
      fromBlock: hex_quantity(from_block),
      toBlock: hex_quantity(to_block)
    }

    case request("eth_getLogs", [filter]) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_logs}
      {:error, reason} -> {:error, reason}
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

      {:ok, %{status: status}} ->
        Logger.warning("chain read failed #{inspect(%{method: method, status: status})}")
        {:error, :chain_unavailable}

      {:error, reason} ->
        Logger.warning("chain read failed #{inspect(%{method: method, reason: reason})}")
        {:error, :chain_unavailable}
    end
  end

  defp quantity("0x" <> hex) when hex != "" do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> {:error, :invalid_quantity}
    end
  end

  defp quantity(_value), do: {:error, :invalid_quantity}

  defp hex_quantity(value), do: "0x" <> (value |> Integer.to_string(16) |> String.downcase())
end
