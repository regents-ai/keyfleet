defmodule KeyfleetWeb.AgentAccountController do
  @moduledoc """
  The agent's account. `open` opens the agent's own account
  (`Keyfleet.Accounts.AgentAccount`): the wallet that signs its requests becomes
  the account's sign-in wallet, and its signed requests then act as the
  account's owner. Opening again answers the same account; an agent a person
  paired is refused, and one network opens at most `:account_open_rate_limit`
  accounts a day.

  The reads answer for the account the agent acts for, as the Claude connector's
  tool of the same name does (`KeyfleetWeb.AgentTools.Account.Answer`).
  """
  use KeyfleetWeb, :controller

  require Logger

  alias Keyfleet.Accounts.{AgentAccount, RequestRateLimiter}
  alias Keyfleet.Actors.Agent
  alias KeyfleetWeb.{AgentReply, ClientAddress, Refusal}
  alias KeyfleetWeb.AgentTools.Account.Answer

  # Opening again answers the account the agent owns.
  def open(%{assigns: %{agent_actor: %Agent{owner?: true} = owner}} = conn, _params),
    do: opened(conn, AgentAccount.open(owner.wallet_address))

  def open(%{assigns: %{agent_actor: %Agent{pairing: :none} = agent}} = conn, _params) do
    case admit(conn) do
      :ok ->
        opened(conn, AgentAccount.open(agent.wallet_address))

      {:limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> refuse(429, "account_openings_limited")
    end
  end

  def open(conn, _params), do: refuse(conn, 409, "agent_paired")

  def balances(conn, params), do: reply(conn, :balances, params)
  def credits_history(conn, _params), do: reply(conn, :credits_history, conn.body_params)
  def points(conn, params), do: reply(conn, :points, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))

  defp admit(conn) do
    budget = Application.fetch_env!(:keyfleet, :account_open_rate_limit)
    {key, _source} = ClientAddress.key(conn)

    case RequestRateLimiter.admit(
           {:account_open, key},
           Keyword.fetch!(budget, :limit),
           Keyword.fetch!(budget, :window_seconds)
         ) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, budget} -> {:limited, budget.reset}
    end
  end

  defp opened(conn, {:ok, account}), do: json(conn, %{account: Keyfleet.Agents.present(account)})
  defp opened(conn, {:error, :wallet_in_use}), do: refuse(conn, 409, "wallet_in_use")
  defp opened(conn, {:error, :wallet_moved}), do: refuse(conn, 409, "account_not_opened")

  # Privy refuses a bad app secret as it refuses a bad request, so each is logged.
  defp opened(conn, {:error, :privy_refused}) do
    Logger.warning("Privy refused opening an agent's account")
    refuse(conn, 409, "account_not_opened")
  end

  defp opened(conn, {:error, error}) do
    Logger.error("Opening an agent's account failed: #{inspect(error)}")
    refuse(conn, 503, "accounts_unavailable")
  end

  defp refuse(conn, status, code),
    do: conn |> put_status(status) |> json(Refusal.body(code))
end
