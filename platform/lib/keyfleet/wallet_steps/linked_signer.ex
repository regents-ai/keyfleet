defmodule Keyfleet.WalletSteps.LinkedSigner do
  @moduledoc """
  The actor is a signed-in person and the signer is one of the wallets their
  own account links.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Actors.Human

  @impl true
  def describe(_opts), do: "the signer is a wallet the signed-in person's account links"

  @impl true
  def match?(%Human{wallet_addresses: wallets}, %{subject: %{arguments: %{signer: signer}}}, _opts)
      when is_binary(signer),
      do: String.downcase(signer) in wallets

  def match?(_actor, _context, _opts), do: false
end
