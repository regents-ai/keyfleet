defmodule KeyFleet.Chain.OwnershipLog do
  @moduledoc """
  Reads `OwnershipEpoch(uint256 indexed tokenId, uint64 epoch, address indexed
  from, address indexed to)` logs of a fleet contract into the fields
  `KeyFleet.Keys.record_epoch/2` takes.
  """

  # cast keccak "OwnershipEpoch(uint256,uint64,address,address)"
  @topic "0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1"

  @doc "The event's topic0."
  def topic, do: @topic

  @doc """
  One log as an ownership epoch of `fleet_id`, or `:error` when it is not a
  well-formed `OwnershipEpoch` log of `contract_address`.
  """
  def decode(
        %{
          "address" => address,
          "topics" => [topic0, token_topic, _from_topic, to_topic],
          "data" => data,
          "blockNumber" => block_number,
          "blockHash" => block_hash,
          "transactionHash" => transaction_hash,
          "logIndex" => log_index
        },
        fleet_id,
        contract_address
      ) do
    with true <- String.downcase(address) == contract_address,
         true <- String.downcase(topic0) == @topic,
         {:ok, token_id} <- word(token_topic),
         {:ok, owner_wallet} <- address_word(to_topic),
         {:ok, ownership_epoch} <- word(data),
         {:ok, block_number} <- quantity(block_number),
         {:ok, block_hash} <- hash(block_hash),
         {:ok, transaction_hash} <- hash(transaction_hash),
         {:ok, log_index} <- quantity(log_index) do
      {:ok,
       %{
         fleet_id: fleet_id,
         token_id: token_id,
         ownership_epoch: ownership_epoch,
         owner_wallet: owner_wallet,
         block_number: block_number,
         block_hash: block_hash,
         transaction_hash: transaction_hash,
         log_index: log_index
       }}
    else
      _malformed -> :error
    end
  end

  def decode(_log, _fleet_id, _contract_address), do: :error

  defp word("0x" <> hex) when byte_size(hex) == 64, do: parse_hex(hex)
  defp word(_value), do: :error

  defp address_word("0x" <> <<padding::binary-size(24), address::binary-size(40)>>) do
    if padding == String.duplicate("0", 24) and match?({:ok, _}, parse_hex(address)),
      do: {:ok, "0x" <> String.downcase(address)},
      else: :error
  end

  defp address_word(_value), do: :error

  defp hash("0x" <> hex = value) when byte_size(hex) == 64 do
    case parse_hex(hex) do
      {:ok, _number} -> {:ok, String.downcase(value)}
      :error -> :error
    end
  end

  defp hash(_value), do: :error

  defp quantity("0x" <> hex) when hex != "", do: parse_hex(hex)
  defp quantity(_value), do: :error

  defp parse_hex(hex) do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> :error
    end
  end
end
