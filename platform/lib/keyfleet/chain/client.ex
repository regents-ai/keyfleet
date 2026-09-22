defmodule KeyFleet.Chain.Client do
  @moduledoc """
  The chain reads the fleet reader needs, answered by a JSON-RPC node in
  production and by a stand-in in tests.

  Logs come back exactly as `eth_getLogs` returns them; decoding them is
  `KeyFleet.Chain.OwnershipLog`'s job.
  """

  @type head :: %{number: non_neg_integer(), hash: String.t()}

  @callback chain_id() :: {:ok, pos_integer()} | {:error, term()}
  @callback head() :: {:ok, head()} | {:error, term()}
  @callback get_logs(
              address :: String.t(),
              topic0 :: String.t(),
              from_block :: non_neg_integer(),
              to_block :: non_neg_integer()
            ) :: {:ok, [map()]} | {:error, term()}
  @callback get_block_hash(block :: non_neg_integer()) :: {:ok, String.t()} | {:error, term()}

  @doc "The client this application is configured with."
  def configured, do: Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:client]
end
