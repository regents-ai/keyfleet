defmodule KeyfleetWeb.AgentChainController do
  @moduledoc """
  The transactions an agent's own wallet sends to act on a fleet's contracts:
  marking its keys present, proposing, voting, cancelling, carrying a
  proposal out, running the daily split and claiming a key's money. Each is
  built by `Keyfleet.WalletSteps` for the signing agent's wallet, as the
  site's buttons are built for a person's, from the chain read at the latest
  block.

  The answer names the chain, says in a line what the transactions do, and
  lists them in the order to send them (`KeyfleetWeb.AgentChainJSON`). Each
  carries `blocked`: why the chain's own state makes it certain to fail now,
  or null. Nothing here sends anything or holds anything back; the agent's
  wallet sends, and the contract decides.

  Proposing saves the proposal's words before answering, so they are on the
  proposal's page once the chain reader records it. A wallet that may not
  vote the Key it names can't make the proposal, so its words are not saved.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.WalletSteps
  alias KeyfleetWeb.AgentChainJSON
  alias KeyfleetWeb.Refusal
  alias KeyfleetWeb.WalletWords

  def presence(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :present, %{})

  def split(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :run_split, %{})

  def propose(conn, %{"fleet_id" => fleet_id}) do
    inputs = conn.body_params

    answer(conn, fleet_id, :propose, %{inputs: inputs}, fn built ->
      if built.figures.governs? do
        {:ok, _words} = Proposals.save_words(fleet_id, inputs["text"], conn.assigns.agent_actor)
      end

      built
    end)
  end

  def vote(conn, %{"fleet_id" => fleet_id, "number" => number, "choice" => choice}) do
    answer(conn, fleet_id, :ballot, %{proposal: number}, fn built ->
      update_in(built.review.steps, fn steps -> Enum.filter(steps, &(&1.step == choice)) end)
    end)
  end

  def cancel(conn, %{"fleet_id" => fleet_id, "number" => number}),
    do: answer(conn, fleet_id, :cancel, %{proposal: number})

  def carry_out(conn, %{"fleet_id" => fleet_id, "number" => number}),
    do: answer(conn, fleet_id, :carry_out, %{proposal: number})

  def claim(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do: answer(conn, fleet_id, :claim, %{token_id: String.to_integer(token_id)})

  defp answer(conn, fleet_id, flow, params, shape \\ &Function.identity/1) do
    agent = conn.assigns.agent_actor

    with {:ok, fleet} <- on_chain(fleet_id),
         :ok <- known(fleet_id, params) do
      built =
        WalletSteps.build_steps!(fleet_id, flow, agent.wallet_address, "agent", params,
          actor: agent
        )

      case built.problem do
        nil -> json(conn, AgentChainJSON.answer(flow, fleet, shape.(built)))
        problem -> refuse(conn, flow, built, problem, Map.get(params, :inputs, %{}))
      end
    else
      {:refuse, status, code} -> Refusal.json(conn, status, code)
      {:key_unknown, token_id} -> Refusal.key_unknown(conn, fleet_id, token_id)
    end
  end

  defp on_chain(fleet_id) do
    case Fleets.get_fleet!(fleet_id) do
      nil -> {:refuse, 404, "fleet_unknown"}
      %{manager_address: nil} -> {:refuse, 409, "fleet_not_on_chain"}
      fleet -> {:ok, fleet}
    end
  end

  # The proposal or key a request names, as the chain reader recorded it.
  defp known(fleet_id, %{proposal: number}) do
    if Proposals.get_proposal!(fleet_id, number),
      do: :ok,
      else: {:refuse, 404, "proposal_unknown"}
  end

  defp known(fleet_id, %{token_id: token_id}) do
    if Keys.current_key!(fleet_id, token_id), do: :ok, else: {:key_unknown, token_id}
  end

  defp known(_fleet_id, _params), do: :ok

  defp refuse(conn, _flow, _built, :unread, _inputs),
    do: Refusal.json(conn, 503, "chain_unavailable")

  defp refuse(conn, _flow, _built, :not_recorded, _inputs),
    do: Refusal.json(conn, 404, "proposal_unknown")

  # Only a proposal's own fields can be written wrong.
  defp refuse(conn, :propose, built, _problem, inputs) do
    body = Refusal.body("invalid_proposal")
    details = %{problem: WalletWords.line(:propose, built, inputs)}

    conn
    |> put_status(422)
    |> json(put_in(body, [:error, :details], details))
  end
end
