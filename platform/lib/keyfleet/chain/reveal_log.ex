defmodule Keyfleet.Chain.RevealLog do
  @moduledoc """
  Reads a fleet contract's `KeyRevealed(uint256 indexed tokenId, uint256
  indexed requestId, bytes32 seed)` logs into the fields `Keyfleet.Keys`
  records.
  """

  alias Keyfleet.Chain.Abi

  # cast keccak "KeyRevealed(uint256,uint256,bytes32)"
  @topic "0x6d40ad718cfc10342a32c87c9bc44d44a37c6e9a218a67e550d1631035b05f0e"

  @doc "The event's topic0."
  def topic, do: @topic

  @doc """
  A `KeyRevealed` log's indexed topics after topic0, as 32-byte words, and its
  data, as a reveal record; `:error` for any other log or a malformed one.
  """
  def decode(@topic, [token_topic, request_topic], data) do
    with {:ok, token_id} when token_id > 0 <- Abi.word(token_topic, {:uint, 63}),
         {:ok, request_id} <- Abi.word(request_topic, {:uint, 256}),
         {:ok, [seed]} <- Abi.decode(data, [:bytes32]) do
      {:ok, {:reveal, %{token_id: token_id, request_id: Decimal.new(request_id), seed: seed}}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error
end
