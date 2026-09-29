defmodule Keyfleet.Chain.ShardsLog do
  @moduledoc """
  Reads a fleet's `KeyfleetShards` logs into the fields `Keyfleet.Keys`
  records: `ShardIssued(uint256 indexed tokenId, address indexed wallet,
  uint64 expiresAt, uint64 epoch)` and `ShardEnded(uint256 indexed tokenId,
  address indexed wallet, address indexed by)`, both as `{:shard, fields}`.
  """

  alias RegentChain.Abi
  alias RegentChain.Event

  @issued Event.topic0("ShardIssued(uint256,address,uint64,uint64)")
  @ended Event.topic0("ShardEnded(uint256,address,address)")

  @doc "The topic0 of every event read here."
  def topics, do: [@issued, @ended]

  @doc """
  A log's indexed topics after topic0, as 32-byte words, and its data, as one
  record; `:error` for any other log or a malformed one.
  """
  def decode(@issued, [token_topic, wallet_topic], data) do
    with {:ok, token_id} when token_id > 0 <- Abi.word(token_topic, {:uint, 63}),
         {:ok, wallet} <- Abi.word(wallet_topic, :address),
         {:ok, [expires_at, epoch]} <- Abi.decode(data, [{:uint, 63}, {:uint, 63}]),
         true <- epoch > 0,
         {:ok, expires_at} <- DateTime.from_unix(expires_at) do
      {:ok,
       {:shard,
        %{
          kind: :issued,
          token_id: token_id,
          wallet: wallet,
          expires_at: expires_at,
          ownership_epoch: epoch,
          ended_by: nil
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(@ended, [token_topic, wallet_topic, by_topic], data) do
    with {:ok, token_id} when token_id > 0 <- Abi.word(token_topic, {:uint, 63}),
         {:ok, wallet} <- Abi.word(wallet_topic, :address),
         {:ok, ended_by} <- Abi.word(by_topic, :address),
         {:ok, []} <- Abi.decode(data, []) do
      {:ok,
       {:shard,
        %{
          kind: :ended,
          token_id: token_id,
          wallet: wallet,
          expires_at: nil,
          ownership_epoch: nil,
          ended_by: ended_by
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error
end
