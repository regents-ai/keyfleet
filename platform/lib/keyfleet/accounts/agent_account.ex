defmodule Keyfleet.Accounts.AgentAccount do
  @moduledoc """
  An account an agent owns: one it opened for itself, whose sign-in wallet is the
  agent's own signing wallet (Sean, 30 Oct 2026, "2. a", as ash-template's G1). The
  agent's signed request then acts for the account as its owner, with no pairing
  (`Keyfleet.Agents.with_pairing/1`).

  The agent opens it with `open/1`. The site asks Privy for the user the wallet
  signs in to, makes one for the agent when there is none, then registers the
  account as a sign-in on the site does and records the opening
  (`Keyfleet.Accounts.AgentOwnedAccount`) in one transaction. An account the
  agent opened on another Regent site is already in the shared accounts table:
  it is taken as it stands, never registered again, and only while its sign-in
  wallet is still the agent's. Only a Privy user an
  agent opening made, here or on another Regent site, is taken
  (`RegentPrivy.Users`, `agent: true`); any other is a person's, even one who signs
  in with nothing but the same wallet.
  """

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.{AgentOwnedAccount, HumanAccount, VerifiedSession}
  alias Keyfleet.Actors.System

  @actor %System{}

  @doc """
  The account `wallet` opened, while the wallet still signs in to it and its
  wallet evidence is current, or nil.
  """
  def owned(wallet) do
    wallet = String.downcase(wallet)

    with {:ok, opened} <- Accounts.get_agent_owned_account(wallet, actor: @actor) do
      case opened do
        %{human_account: %{wallet_address: ^wallet} = account} ->
          {:ok, if(VerifiedSession.current?(account), do: account)}

        _none_or_moved ->
          {:ok, nil}
      end
    end
  end

  @doc "How an agent's whoami names the account it owns (`config :regent_agents, owned_account:`)."
  def owned_account(wallet) do
    case owned(wallet) do
      {:ok, %{} = account} -> Keyfleet.Agents.present(account)
      _none_or_unreadable -> nil
    end
  end

  @doc """
  Opens the account `wallet` owns, or answers the one it already owns. Errors
  are `:wallet_in_use` (the wallet signs in to a person's account),
  `:wallet_moved` (the agent's account now signs in with another wallet), Privy's
  `:missing_privy_config`, `:privy_refused` and `:privy_unavailable`
  (`RegentPrivy.Users`), or the database's own.
  """
  def open(wallet) do
    wallet = String.downcase(wallet)

    with {:ok, nil} <- owned(wallet),
         {:ok, did} <- privy_user(wallet),
         {:ok, existing} <- Accounts.get_by_privy_did(did, actor: @actor),
         :ok <- unmoved(existing, wallet),
         {:ok, {:ok, account}} <-
           Ash.transact([HumanAccount, AgentOwnedAccount], fn -> take(existing, did, wallet) end) do
      {:ok, account}
    end
  end

  defp unmoved(nil, _wallet), do: :ok

  defp unmoved(%{wallet_address: wallet} = account, wallet),
    do: if(VerifiedSession.current?(account), do: :ok, else: {:error, :wallet_moved})

  defp unmoved(_moved, _wallet), do: {:error, :wallet_moved}

  defp take(existing, did, wallet) do
    with {:ok, account} <- account(existing, did, wallet),
         {:ok, _opened} <-
           Accounts.record_agent_owned_account(
             %{wallet_address: wallet, human_account_id: account.id},
             actor: @actor
           ) do
      {:ok, account}
    end
  end

  defp account(nil, did, wallet), do: VerifiedSession.register(did, wallet, [wallet])
  defp account(existing, _did, _wallet), do: {:ok, existing}

  defp privy_user(wallet) do
    privy = Application.get_env(:keyfleet, :privy, [])

    case RegentPrivy.Users.by_wallet(wallet, privy) do
      {:ok, %{privy_user_id: did, agent: true}} -> {:ok, did}
      {:ok, %{agent: false}} -> {:error, :wallet_in_use}
      {:error, :not_found} -> made(RegentPrivy.Users.create_with_wallet(wallet, privy))
      {:error, error} -> {:error, error}
    end
  end

  defp made({:ok, %{privy_user_id: did}}), do: {:ok, did}
  defp made({:error, error}), do: {:error, error}
end
