defmodule Keyfleet.Points.Accounts do
  @moduledoc "Verified account lookups supplied to the shared Points package."
  @behaviour RegentPoints.Accounts

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System

  @impl true
  def human(id), do: Accounts.points_account!(id, actor: %System{})

  @impl true
  def agent_names(_id, []), do: {:ok, %{}}

  # Points names an agent by its wallet; a wallet paired again keeps its latest name.
  def agent_names(id, wallets) do
    with {:ok, account} <- Accounts.points_account(id, actor: %System{}),
         {:ok, pairings} <- RegentAgents.pairing_histories(account.privy_user_id) do
      names =
        for pairing <- pairings,
            pairing.wallet in wallets,
            into: %{},
            do: {pairing.wallet, pairing.name}

      {:ok, names}
    end
  end
end
