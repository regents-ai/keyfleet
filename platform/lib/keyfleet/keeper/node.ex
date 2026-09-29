defmodule Keyfleet.Keeper.Node do
  @moduledoc """
  What the keeper asks of the chain: a JSON-RPC node in production
  (`Keyfleet.Keeper.RpcNode`) and a stand-in in tests.

  Everything is read at the latest block; nothing waits for Ethereum's
  `safe` or `finalized` blocks. Addresses and hashes are lowercase `0x`
  strings, amounts are wei and data is bytes.

  A call or estimate the contract refuses is
  `{:error, {:revert, selector, args}}`: the four-byte selector of the
  contract's error and its encoded arguments, or `nil` and whatever bytes
  came back when there is no selector.
  """

  @type revert :: {:revert, <<_::32>> | nil, binary()}

  @type block :: %{
          number: non_neg_integer(),
          timestamp: non_neg_integer(),
          base_fee: non_neg_integer()
        }

  @typedoc """
  A mined transaction's receipt: `status` 1 for success and 0 for a revert,
  what it cost and the logs it emitted, exactly as the node returned them.
  """
  @type receipt :: %{
          status: 0 | 1,
          block_number: non_neg_integer(),
          gas_used: non_neg_integer(),
          effective_gas_price: non_neg_integer(),
          logs: [map()]
        }

  @callback chain_id() :: {:ok, pos_integer()} | {:error, term()}
  @callback latest_block() :: {:ok, block()} | {:error, term()}
  @callback call(from :: String.t(), to :: String.t(), data :: binary()) ::
              {:ok, binary()} | {:error, revert() | term()}
  @callback estimate_gas(from :: String.t(), to :: String.t(), data :: binary()) ::
              {:ok, pos_integer()} | {:error, revert() | term()}
  @callback balance(address :: String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback nonce(address :: String.t(), :latest | :pending) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback max_priority_fee() :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Sends a signed transaction and returns its hash."
  @callback send_raw(raw :: binary()) :: {:ok, String.t()} | {:error, term()}

  @doc "The receipt of a transaction, or `{:ok, nil}` while it has none."
  @callback receipt(tx_hash :: String.t()) :: {:ok, receipt() | nil} | {:error, term()}

  @doc "The node this application is configured with."
  def configured, do: Application.fetch_env!(:keyfleet, Keyfleet.Keeper)[:node]
end
