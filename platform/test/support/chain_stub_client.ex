defmodule KeyFleet.Chain.StubClient do
  @moduledoc """
  The chain as a test describes it: a chain id, a head, a list of raw logs and
  the hash of each block, held in the calling process so tests running side by
  side never share one. It also keeps every log request it was asked, so a test
  can see how the chain was asked.

  Like a real node, it knows nothing above its head: a head behind the logs
  stands for a node that has not caught up.
  """

  @behaviour KeyFleet.Chain.Client

  # Every block's hash unless a test names another, and the hash the chain
  # tests give each log.
  @block_hash "0x" <> String.duplicate("b", 64)

  @doc """
  Sets the head and the logs the chain answers with. `opts` may name the
  `:chain_id` (8453), `:block_hashes`, a map from block number to the hash
  that block has now, `:max_logs`, the most logs one answer may hold, as a
  provider limits the size of an answer; a request for more fails, and
  `:observe`, a function called as each log request arrives, whose results
  `observations/0` returns.
  """
  def put_chain(head, logs, opts \\ []) do
    Process.put(__MODULE__, %{
      head: head,
      logs: logs,
      chain_id: Keyword.get(opts, :chain_id, 8_453),
      block_hashes: Keyword.get(opts, :block_hashes, %{}),
      max_logs: Keyword.get(opts, :max_logs),
      observe: Keyword.get(opts, :observe, fn -> nil end),
      log_requests: [],
      observations: []
    })
  end

  @doc "Every `get_logs/4` request since `put_chain/3`, oldest first."
  def log_requests, do: Enum.reverse(chain().log_requests)

  @doc "What `:observe` returned as each log request arrived, oldest first."
  def observations, do: Enum.reverse(chain().observations)

  @impl true
  def chain_id, do: {:ok, chain().chain_id}

  @impl true
  def head, do: {:ok, chain().head}

  @impl true
  def get_logs(addresses, topic0s, from, to) do
    %{head: head, logs: logs, max_logs: max_logs, observe: observe} = chain = chain()

    Process.put(__MODULE__, %{
      chain
      | log_requests: [{addresses, topic0s, from, to} | chain.log_requests],
        observations: [observe.() | chain.observations]
    })

    found =
      Enum.filter(logs, fn log ->
        block = log |> Map.fetch!("blockNumber") |> quantity()

        String.downcase(log["address"]) in addresses and hd(log["topics"]) in topic0s and
          block in from..min(to, head.number)//1
      end)

    if max_logs && length(found) > max_logs,
      do: {:error, :chain_unavailable},
      else: {:ok, found}
  end

  @impl true
  def get_block_hash(block) do
    %{head: head, block_hashes: hashes} = chain()

    if block <= head.number,
      do: {:ok, Map.get(hashes, block, @block_hash)},
      else: {:error, :block_unavailable}
  end

  defp chain, do: Process.get(__MODULE__) || raise("call put_chain/2 before reading the chain")

  defp quantity("0x" <> hex), do: String.to_integer(hex, 16)
end
