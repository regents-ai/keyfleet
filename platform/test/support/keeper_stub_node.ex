defmodule KeyFleet.Keeper.StubNode do
  @moduledoc """
  The chain as a keeper test describes it, held for the test that set it up
  and for any process that test starts, so tests running side by side never
  share one. The keeper's wallet is its only sender.

  Every transaction the node accepts is kept, raw, oldest first. By default
  it accepts each one and mines it at once with status 1: it gets a receipt
  in the newest block, and the latest and pending nonces move past it. Each
  read of the latest block finds the one after the block read before.
  """

  @behaviour KeyFleet.Keeper.Node

  @doc """
  Sets up the chain. `opts` may name the `:chain_id` (8453); the latest
  `:block` (number, timestamp and base fee); the `:max_priority_fee`; the
  wallet's `:balance`; its `:nonce`, the latest, and `:pending`, which is the
  latest unless given; `:calls` and `:estimate`, functions answering
  `call(from, to, data)` and `estimate_gas(from, to, data)` (none answered,
  and 100,000 gas); `:send`, a function given the number of the attempt to
  send, from 1, and its raw bytes that returns `:ok` to accept it, `{:ok,
  hash}` to accept it under that hash, or `{:error, reason}` to refuse it;
  `:mine`, a function given the number of the accepted send, from 1, and its
  raw bytes that returns `{:mined, status}`, `{:mined, status, logs}` for a
  receipt with those logs, or `:pending`; and `:receipt`,
  the gas used, gas price and L1 fee each mined receipt shows.
  """
  def put_chain(opts \\ []) do
    nonce = Keyword.get(opts, :nonce, 0)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          chain_id: Keyword.get(opts, :chain_id, 8_453),
          block:
            Keyword.get(opts, :block, %{
              number: 1_000,
              timestamp: 1_800_000_000,
              base_fee: 5_000_000
            }),
          max_priority_fee: Keyword.get(opts, :max_priority_fee, 1_000_000),
          balance: Keyword.get(opts, :balance, 50_000_000_000_000_000),
          latest: nonce,
          pending: Keyword.get(opts, :pending, nonce),
          calls: Keyword.get(opts, :calls, fn _from, _to, _data -> {:error, :no_answer} end),
          estimate: Keyword.get(opts, :estimate, fn _from, _to, _data -> {:ok, 100_000} end),
          send: Keyword.get(opts, :send, fn _attempt, _raw -> :ok end),
          attempts: 0,
          mine: Keyword.get(opts, :mine, fn _n, _raw -> {:mined, 1} end),
          receipt:
            Map.merge(
              %{gas_used: 60_000, effective_gas_price: 6_000_000, l1_fee: 2_000},
              Keyword.get(opts, :receipt, %{})
            ),
          sent: [],
          receipts: %{},
          later: []
        }
      end)

    Process.put(__MODULE__, agent)
    :ok
  end

  @doc "Every transaction sent, raw, oldest first."
  def sent, do: get(&Enum.reverse(&1.sent))

  @doc "Changes what the chain answers from now on; `opts` as in `put_chain/1`."
  def update(opts), do: Agent.update(agent(), &Map.merge(&1, Map.new(opts)))

  @doc "Mines a transaction already sent, with `status`."
  def mine(tx_hash, status), do: Agent.update(agent(), &mined(&1, tx_hash, status, []))

  @doc """
  Gives a transaction already sent a receipt with `status` in the next block
  read, as a node whose receipts lag its nonces would; the nonces are left
  as they are.
  """
  def mine_later(tx_hash, status),
    do: Agent.update(agent(), &%{&1 | later: [{tx_hash, status, []} | &1.later]})

  @impl true
  def chain_id, do: {:ok, get(& &1.chain_id)}

  @impl true
  def latest_block do
    {:ok,
     Agent.get_and_update(agent(), fn chain ->
       next = %{chain | block: %{chain.block | number: chain.block.number + 1}, later: []}
       {chain.block, Enum.reduce(chain.later, next, &receipted(&2, &1))}
     end)}
  end

  @impl true
  def call(from, to, data), do: get(& &1.calls).(from, to, data)

  @impl true
  def estimate_gas(from, to, data), do: get(& &1.estimate).(from, to, data)

  @impl true
  def balance(_address), do: {:ok, get(& &1.balance)}

  @impl true
  def nonce(_address, :latest), do: {:ok, get(& &1.latest)}
  def nonce(_address, :pending), do: {:ok, get(& &1.pending)}

  @impl true
  def max_priority_fee, do: {:ok, get(& &1.max_priority_fee)}

  @impl true
  def send_raw(raw) do
    tx_hash = "0x" <> Base.encode16(ExKeccak.hash_256(raw), case: :lower)

    Agent.get_and_update(agent(), fn chain ->
      chain = %{chain | attempts: chain.attempts + 1}

      case chain.send.(chain.attempts, raw) do
        :ok -> {{:ok, tx_hash}, accepted(chain, tx_hash, raw)}
        {:ok, hash} -> {{:ok, hash}, accepted(chain, tx_hash, raw)}
        {:error, reason} -> {{:error, reason}, chain}
      end
    end)
  end

  defp accepted(chain, tx_hash, raw) do
    chain = %{chain | sent: [raw | chain.sent]}

    case chain.mine.(length(chain.sent), raw) do
      {:mined, status} -> mined(chain, tx_hash, status, [])
      {:mined, status, logs} -> mined(chain, tx_hash, status, logs)
      :pending -> chain
    end
  end

  @impl true
  def receipt(tx_hash), do: {:ok, get(&Map.get(&1.receipts, tx_hash))}

  defp mined(chain, tx_hash, status, logs) do
    chain = receipted(chain, {tx_hash, status, logs})
    latest = chain.latest + 1
    %{chain | latest: latest, pending: max(chain.pending, latest)}
  end

  defp receipted(chain, {tx_hash, status, logs}) do
    receipt =
      Map.merge(chain.receipt, %{status: status, block_number: chain.block.number, logs: logs})

    %{chain | receipts: Map.put(chain.receipts, tx_hash, receipt)}
  end

  defp get(fun), do: Agent.get(agent(), fun)

  # The test's own process, or for a process it started, the test's.
  defp agent do
    Enum.find_value([self() | Process.get(:"$ancestors", [])], fn
      pid when is_pid(pid) ->
        {:dictionary, dictionary} = Process.info(pid, :dictionary)

        case List.keyfind(dictionary, __MODULE__, 0) do
          {__MODULE__, agent} -> agent
          nil -> nil
        end

      _name ->
        nil
    end) || raise "call put_chain/1 before using the keeper's node"
  end
end
