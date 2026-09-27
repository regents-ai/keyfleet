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
    end
  end
end
