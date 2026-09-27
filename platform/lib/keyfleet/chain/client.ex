defmodule Keyfleet.Chain.Client do
  @moduledoc """
  The chain reads the fleet reader needs, answered by a JSON-RPC node in
  production and by a stand-in in tests.

  Logs come back exactly as `eth_getLogs` returns them; decoding them is
  `Keyfleet.Chain.Logs`'s job. Contract reads come back as the bytes the
  contract returned. One call asks for every contract and event the
  reader follows, so a stretch of blocks is always read whole.
  """

  @type head :: %{number: non_neg_integer(), hash: String.t(), timestamp: DateTime.t()}

  @callback chain_id() :: {:ok, pos_integer()} | {:error, term()}
  @callback head() :: {:ok, head()} | {:error, term()}
  @callback get_logs(
              addresses :: [String.t()],
              topic0s :: [String.t()],
              from_block :: non_neg_integer(),
              to_block :: non_neg_integer()
            ) :: {:ok, [map()]} | {:error, term()}
  @callback get_block_hash(block :: non_neg_integer()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Calls a contract's view function with `data`, the `0x` calldata
  `RegentChain.Call.encode/2` builds, at the block whose hash is
  `block_hash`, and returns the bytes it returned. A call the contract refuses is
  `{:error, :reverted}`. A block that is no longer on the chain is an error,
  never another block's answer.
  """
  @callback call(to :: String.t(), data :: String.t(), block_hash :: String.t()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  The transaction sent as `hash`, as `eth_getTransactionByHash` answers at
  `latest`, or `nil` while the node does not know it. `chain` is the chain a
  server-built wallet step names, which is always the fleet's and so this
  node's; `RegentChain.Outcome` reads sent steps through this and `receipt/2`.
  """
  @callback transaction(chain :: map(), hash :: String.t()) ::
              {:ok, map() | nil} | {:error, term()}

  @doc "The receipt of `hash` at `latest`, or `nil` while it has not landed."
  @callback receipt(chain :: map(), hash :: String.t()) :: {:ok, map() | nil} | {:error, term()}

  @doc "The client this application is configured with."
  def configured, do: Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:client]
end
