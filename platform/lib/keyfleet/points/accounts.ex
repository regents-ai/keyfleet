defmodule Keyfleet.Points.Accounts do
  @moduledoc "Verified account lookups supplied to the shared Points package."
  @behaviour RegentPoints.Accounts

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias Keyfleet.PublicIdentity

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

  # What the board shows of each account: its name or wallet, and its pictures.
  @impl true
  def people([]), do: {:ok, %{}}

  def people(ids) do
    with {:ok, accounts} <-
           Accounts.accounts_by_ids(ids,
             actor: %System{},
             load: [:display_name, :ens_name, :ens_avatar_url]
           ) do
      {:ok,
       Map.new(accounts, fn account ->
         {account.id,
          %{
            name: PublicIdentity.listed_name(account),
            wallet: PublicIdentity.wallet(account),
            ens_name: PublicIdentity.ens_name(account),
            squares: PublicIdentity.squares(account),
            picture: PublicIdentity.picture(account)
          }}
       end)}
    end
  end
end
