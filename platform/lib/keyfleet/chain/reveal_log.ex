defmodule Keyfleet.Chain.RevealLog do
  @moduledoc """
  Reads the Key collection's `KeyRevealed(uint256 indexed tokenId, uint256
  indexed fleetId, uint256 keyNumber, uint256 indexed requestId, bytes32
  seed)` logs into the fields `Keyfleet.Keys` records. The token id must be
  the one the collection gives that fleet's Key number.
  """

  alias Keyfleet.Fleets.Fleet
  alias RegentChain.Abi
  alias RegentChain.Event

  @topic Event.topic0("KeyRevealed(uint256,uint256,uint256,uint256,bytes32)")

  @doc "The event's topic0."
  def topic, do: @topic

  @doc """
  A `KeyRevealed` log's indexed topics after topic0, as 32-byte words, and its
  data, as a reveal record naming the Key by its token id; `:error` for any
  other log or a malformed one.
  """
  def decode(@topic, [token_topic, fleet_topic, request_topic], data) do
    with {:ok, token_id} when token_id > 0 <- Abi.word(token_topic, {:uint, 63}),
         {:ok, fleet} when fleet > 0 <- Abi.word(fleet_topic, {:uint, 63}),
         {:ok, request_id} <- Abi.word(request_topic, {:uint, 256}),
         {:ok, [key_number, seed]} <- Abi.decode(data, [{:uint, 63}, :bytes32]),
         true <- key_number > 0 and Fleet.onchain_token_id(%{chain_fleet_id: fleet}, key_number) == token_id do
      {:ok, {:reveal, %{token_id: token_id, request_id: Decimal.new(request_id), seed: seed}}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error
end
