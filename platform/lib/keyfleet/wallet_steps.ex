defmodule Keyfleet.WalletSteps do
  @moduledoc """
  The steps a person's wallet sends from Keyfleet's wallet buttons, built on
  the server for the one wallet that may send them. Pages push the built
  steps to the browser before anyone presses; the browser never encodes a
  transaction. Any route that offers the same actions builds them here too.
  """
  use Ash.Domain

  resources do
    resource Keyfleet.WalletSteps.Steps do
      define :build_steps, action: :build, args: [:fleet_id, :flow, :signer, :component_id]
      define :read_figures, action: :figures, args: [:fleet_id, :flow]
    end
  end

  @doc """
  The chain a fleet on `chain_id` sends to, as a wallet is shown it:
  `%{chain_id: id, name: name, rpc_url: url}` from `:wallet_chains`, or nil
  when the site sets none for it.
  """
  def chain(chain_id) do
    case Application.fetch_env!(:keyfleet, :wallet_chains) do
      %{^chain_id => %{name: name, rpc_url: rpc_url}} ->
        %{chain_id: chain_id, name: name, rpc_url: rpc_url}

      _unlisted ->
        nil
    end
  end
end
