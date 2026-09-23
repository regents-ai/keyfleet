defmodule KeyFleet.Chain.Client do
  @moduledoc """
  The chain reads the fleet reader needs, answered by a JSON-RPC node in
  production and by a stand-in in tests.

  Logs come back exactly as `eth_getLogs` returns them; decoding them is
  `KeyFleet.Chain.Logs`'s job. Contract reads come back as the bytes the
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
  Calls a contract's view function with `data` at the block whose hash is
  `block_hash`, and returns what it returned. A block that is no longer on
  the chain is an error, never another block's answer.
  """
  @callback call(to :: String.t(), data :: binary(), block_hash :: String.t()) ::
              {:ok, binary()} | {:error, term()}

  @doc "The client this application is configured with."
  def configured, do: Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:client]
end
