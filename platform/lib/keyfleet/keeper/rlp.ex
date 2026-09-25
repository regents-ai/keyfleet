defmodule Keyfleet.Keeper.Rlp do
  @moduledoc """
  Recursive-length-prefix encoding, the byte form of an Ethereum transaction.

  An item is a binary, a non-negative integer (big-endian with no leading
  zeros, so 0 is the empty string) or a list of items.
  """

  @doc "The RLP encoding of `item`."
  def encode(item) when is_binary(item), do: encode_bytes(item)

  def encode(item) when is_integer(item) and item >= 0,
    do: item |> :binary.encode_unsigned() |> trim() |> encode_bytes()

  def encode(items) when is_list(items) do
    payload = IO.iodata_to_binary(Enum.map(items, &encode/1))
    prefix(0xC0, payload) <> payload
  end

  defp trim(<<0>>), do: <<>>
  defp trim(bytes), do: bytes

  defp encode_bytes(<<byte>>) when byte < 0x80, do: <<byte>>
  defp encode_bytes(bytes), do: prefix(0x80, bytes) <> bytes

  defp prefix(offset, payload) when byte_size(payload) < 56,
    do: <<offset + byte_size(payload)>>

  defp prefix(offset, payload) do
    length = :binary.encode_unsigned(byte_size(payload))
    <<offset + 55 + byte_size(length)>> <> length
  end
end
