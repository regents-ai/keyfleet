defmodule KeyFleet.Actors.Agent do
  @moduledoc """
  Product principal constructed by trusted code after SIWA wallet verification.

  This struct is not proof by itself and must never be deserialized from client
  input. Its authority covers the wallet's profile, not NFTs or fleet finances.
  """
  @enforce_keys [:wallet_address, :chain_id, :audience]
  defstruct [:wallet_address, :chain_id, :audience]

  @type t :: %__MODULE__{wallet_address: String.t(), chain_id: 8453, audience: String.t()}

  def valid?(%__MODULE__{wallet_address: wallet, chain_id: 8453, audience: "keyfleet"})
      when is_binary(wallet),
      do: Regex.match?(~r/\A0x[0-9a-f]{40}\z/, wallet)

  def valid?(_), do: false
end
