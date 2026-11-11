defmodule KeyfleetWeb.AgentChainController do
  @moduledoc """
  The transactions an agent's own wallet sends to act on a fleet's contracts:
  marking its keys present, proposing, voting, cancelling, carrying a
  proposal out, running the daily split, sending the REGENT staking share,
  turning waiting USDC into REGENT, claiming one key's money or every key's
  at once, buying the next Key, claiming a Regents Club Key with its Pass,
  asking again for a Key's draw or ending a wait for it that ran out,
  returning an advance, the token launch's upkeep, and, as a Key's holder,
  issuing, renewing and ending its shards and turning its shards' voting on
  or off. Each is built by
  `Keyfleet.WalletSteps` for the signing agent's wallet, as the site's
  buttons are built for a person's, from the chain read at the latest block.

  The answer names the chain, says in a line what the transactions do, and
  lists them in the order to send them (`KeyfleetWeb.AgentChainJSON`). Each
  carries `blocked`: why the chain's own state makes it certain to fail now,
  or null. Nothing here sends anything or holds anything back; the agent's
  wallet sends, and the contract decides.

  Proposing saves the proposal's words before answering, so they are on the
  proposal's page once the chain reader records it. Words that can't be kept
  now, or past the wallet's allowance, are left unsaved and the steps are still
  answered, as a person's Propose press goes ahead without them. A wallet that
  may not vote the Key it names can't make the proposal, so its words are not
  saved.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.Errors.WordsLimitError
  alias Keyfleet.WalletSteps
  alias KeyfleetWeb.AgentChainJSON
  alias KeyfleetWeb.Refusal
  alias KeyfleetWeb.WalletWords

  def presence(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :present, %{})

  def split(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :run_split, %{})

  def send_share(conn, %{"fleet_id" => fleet_id}),
    do: answer(conn, fleet_id, :send_share, %{})

  def convert(conn, %{"fleet_id" => fleet_id, "inputs" => inputs}),
    do: answer(conn, fleet_id, :convert, %{inputs: inputs})

  def propose(conn, %{"fleet_id" => fleet_id}) do
    inputs = conn.body_params

    answer(conn, fleet_id, :propose, %{inputs: inputs}, fn built ->
      if built.figures.governs?,
        do: keep_words(fleet_id, inputs["text"], conn.assigns.agent_actor)

      built
    end)
  end

  def vote(conn, %{"fleet_id" => fleet_id, "number" => number, "choice" => choice}),
    do: answer(conn, fleet_id, :ballot, %{proposal: number}, &only(&1, choice))

  def cancel(conn, %{"fleet_id" => fleet_id, "number" => number}),
    do: answer(conn, fleet_id, :cancel, %{proposal: number})

  def carry_out(conn, %{"fleet_id" => fleet_id, "number" => number}),
    do: answer(conn, fleet_id, :carry_out, %{proposal: number})

  def claim(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do: answer(conn, fleet_id, :claim, %{token_id: String.to_integer(token_id)})

  def claim_all(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :claim_all, %{})

  # The next Key at its price, approving exactly the most the purchase may
  # cost, as the Buy Key window does with Unlimited unticked.
  def buy(conn, %{"fleet_id" => fleet_id}), do: answer(conn, fleet_id, :buy, %{})

  # Shards of the Keys named, for the wallet and days named, as the Key
  # page's New shard sends them.
  def issue_shard(conn, %{"fleet_id" => fleet_id}),
    do:
      answer(conn, fleet_id, :issue_shard, %{
        inputs: Map.take(conn.body_params, ~w(keys wallet days))
      })

  # Ending each of the Key's active shards now, and renewing it.
  def end_shard(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do: answer(conn, fleet_id, :end_shard, %{token_id: String.to_integer(token_id)})

  # Whether the shards of the Keys named may vote and propose with them: the
  # one step that turns it on or off.
  def agent_voting(conn, %{"fleet_id" => fleet_id, "keys" => keys, "voting" => voting}),
    do: answer(conn, fleet_id, :agent_voting, %{inputs: %{"keys" => keys}}, &only(&1, voting))

  # Taking Regents Club Key N, with what it earned while it waited, for the
  # holder of Regents Club Pass N.
  def club_claim(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do: answer(conn, fleet_id, :club_claim, %{token_id: String.to_integer(token_id)})

  # Asking again for a Key's random draw, which anyone may do while its
  # request was refused.
  def reveal(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do:
      answer(
        conn,
        fleet_id,
        :reveal,
        %{token_id: String.to_integer(token_id)},
        &only(&1, "reveal")
      )

  # Ending the wait for a Key's draw that hasn't come 24 hours after its
  # request was accepted, which anyone may do. The Key then never gets traits.
  def expire_reveal(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}),
    do:
      answer(
        conn,
        fleet_id,
        :reveal,
        %{token_id: String.to_integer(token_id)},
        &only(&1, "expire_reveal")
      )

  # Part or all of one advance, back to the treasury from the signing wallet,
  # as the treasury page's Return field types it.
  def return_advance(conn, %{"fleet_id" => fleet_id, "advance_id" => id, "amount" => amount}),
    do:
      answer(conn, fleet_id, :return_advance, %{
        advance_id: String.to_integer(id),
        inputs: %{"amount" => amount}
      })

  # One of the token launch's four upkeep buttons: the one asked for.
  def launch_upkeep(conn, %{"fleet_id" => fleet_id, "step" => step}),
    do: answer(conn, fleet_id, :launch_upkeep, %{}, &only(&1, step))

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

  # The one step of a group of buttons that was asked for.
  defp only(built, name),
    do: update_in(built.review.steps, fn steps -> Enum.filter(steps, &(&1.step == name)) end)

  # Words past the wallet's allowance stay unsaved; any other failure is saved
  # with the site's errors. The steps are answered either way.
  defp keep_words(fleet_id, text, agent) do
    case Proposals.save_words(fleet_id, text, agent) do
      {:ok, _words} ->
        :ok

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        unless Enum.any?(errors, &match?(%WordsLimitError{}, &1)),
          do: Keyfleet.Alert.report(error)

      {:error, error} ->
        if is_exception(error), do: Keyfleet.Alert.report(error)
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

  defp refuse(conn, :buy, _built, :not_for_sale, _inputs),
    do: Refusal.json(conn, 409, "keys_not_for_sale")

  defp refuse(conn, :buy, _built, :sold_out, _inputs),
    do: Refusal.json(conn, 409, "keys_sold_out")

  defp refuse(conn, :club_claim, _built, :not_club, _inputs),
    do: Refusal.json(conn, 409, "not_club_key")

  defp refuse(conn, :return_advance, _built, :advance_unknown, _inputs),
    do: Refusal.json(conn, 404, "advance_unknown")

  defp refuse(conn, :launch_upkeep, _built, :no_launch, _inputs),
    do: Refusal.json(conn, 409, "no_launch")

  # Only a proposal's own fields, the amounts to turn into REGENT and to
  # return, and the Keys, wallet and days of shards can be written wrong.
  defp refuse(conn, :propose, built, _problem, inputs),
    do: unreadable(conn, "invalid_proposal", WalletWords.line(:propose, built, inputs))

  defp refuse(conn, flow, built, _problem, inputs) when flow in [:issue_shard, :agent_voting],
    do: unreadable(conn, "invalid_shard", WalletWords.line(flow, built, inputs))

  defp refuse(conn, flow, built, _problem, inputs) when flow in [:convert, :return_advance],
    do: unreadable(conn, "invalid_amount", WalletWords.line(flow, built, inputs))

  defp unreadable(conn, code, problem) do
    conn
    |> put_status(422)
    |> json(put_in(Refusal.body(code), [:error, :details], %{problem: problem}))
  end
end
