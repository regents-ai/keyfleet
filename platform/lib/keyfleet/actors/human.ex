defmodule Keyfleet.Actors.Human do
  @moduledoc "A signed-in person: the account's id and every wallet it links, lowercased."
  @enforce_keys [:human_account_id]
  defstruct [:human_account_id, wallet_addresses: [], role: :human]

  def for_account(account),
    do: %__MODULE__{human_account_id: account.id, wallet_addresses: wallets(account)}

  defp wallets(account) do
    [account.wallet_address | List.wrap(account.wallet_addresses)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
