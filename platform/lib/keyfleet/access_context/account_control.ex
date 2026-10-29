defmodule Keyfleet.AccessContext.AccountControl do
  @moduledoc """
  Ash-owned shell view model for the account target. `wallet` is the account's
  own wallet, and `ens_name` the name its wallet's ENS record gives, shown as
  that wallet in the account menu.
  """

  @enforce_keys [:kind, :label]
  defstruct @enforce_keys ++ [avatar_src: nil, wallet: nil, ens_name: nil]
end
