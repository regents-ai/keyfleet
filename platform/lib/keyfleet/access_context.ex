defmodule Keyfleet.AccessContext do
  @moduledoc "Principal-aware access context for public shell routes."

  alias __MODULE__.AccountControl
  alias Keyfleet.PublicIdentity

  @enforce_keys [:principal, :capabilities]
  defstruct @enforce_keys

  def anonymous, do: %__MODULE__{principal: :anonymous, capabilities: [:view_public]}

  def human(account), do: %__MODULE__{principal: {:human, account}, capabilities: [:view_public]}

  @doc """
  The signed-in account's own wallets, lowercase and each once: the only wallets
  that may act for it. `nil` when signed out.
  """
  def linked_wallets(%__MODULE__{principal: {:human, account}}),
    do: account.wallet_addresses |> Enum.map(&String.downcase/1) |> Enum.uniq()

  def linked_wallets(%__MODULE__{principal: :anonymous}), do: nil

  def account_control(%__MODULE__{principal: :anonymous}) do
    %AccountControl{kind: :sign_in, label: "Sign In"}
  end

  def account_control(%__MODULE__{principal: {:human, account}}) do
    %AccountControl{
      kind: :signed_in,
      label: PublicIdentity.label(account),
      avatar_src: PublicIdentity.avatar_src(account)
    }
  end
end
