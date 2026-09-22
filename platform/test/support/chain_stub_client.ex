defmodule KeyFleet.Chain.StubClient do
  @moduledoc """
  The chain as a test describes it: a chain id, a head, a list of raw logs and
  the hash of each block, held in the calling process so tests running side by
  side never share one.

  Like a real node, it knows nothing above its head: a head behind the logs
  stands for a node that has not caught up.
  """

  @behaviour KeyFleet.Chain.Client

  # Every block's hash unless a test names another, and the hash the chain
  # tests give each log.
  @block_hash "0x" <> String.duplicate("b", 64)

  @doc """
  Sets the head and the logs the chain answers with. `opts` may name the
  `:chain_id` (8453) and `:block_hashes`, a map from block number to the hash
  that block has now.
  """
  def put_chain(head, logs, opts \\ []) do
    Process.put(__MODULE__, %{
      head: head,
      logs: logs,
      chain_id: Keyword.get(opts, :chain_id, 8_453),
      block_hashes: Keyword.get(opts, :block_hashes, %{})
    })
  end

  @impl true
  def chain_id, do: {:ok, chain().chain_id}

  @impl true
  def head, do: {:ok, chain().head}

  @impl true
  def get_logs(address, topic0, from, to) do
    %{head: head, logs: logs} = chain()

    {:ok,
     Enum.filter(logs, fn log ->
       block = log |> Map.fetch!("blockNumber") |> quantity()

       log["address"] |> String.downcase() == address and hd(log["topics"]) == topic0 and
         block in from..min(to, head.number)//1
     end)}
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
