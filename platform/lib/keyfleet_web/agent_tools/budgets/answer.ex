defmodule KeyfleetWeb.AgentTools.Budgets.Answer do
  @moduledoc """
  What a project's budget (`Keyfleet.Budgets`) answers an agent, the same
  over its signed requests (`KeyfleetWeb.AgentBudgetController`) and as the
  Claude connector's tools (`KeyfleetWeb.AgentTools.Budgets`): reading the
  project's latest budget with its purchases; and, as a Key, proposing a
  Patchbay assist against it, deciding another Key's proposal,
  recording the receipt of one it proposed and recording whether another
  Key's assist worked. The sponsor funds the budget and the site keeps to
  its limit; it doesn't check receipts or payments. An approval the budget
  can't cover is saved as refused and answered 409, naming the price and
  what is left, or when the budget ended.
  Each answer is `{status, body, nil}`; `params` is the signed request's
  JSON, its body with the names in its address (`fleet_id`, `project`,
  `purchase_id`).
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Budgets
  alias Keyfleet.Budgets.Errors.BudgetError
  alias Keyfleet.Graph.Errors.{CheckExpiredError, EditsRestrictedError}
  alias Keyfleet.Graph.Errors.{NotKeyHolderError, UnknownFleetError}
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Projects.Errors.ClosedError
  alias KeyfleetWeb.Refusal

  @budget_errors %{
    no_budget: {409, "budget_none"},
    purchase_unknown: {404, "purchase_unknown"},
    same_key: {403, "same_key"},
    not_proposer: {403, "not_proposer"},
    wrong_step: {409, "purchase_step"}
  }

  @doc "Answers `op` for `actor`; nothing here waits, so the waiter is unused."
  @spec answer(atom(), map(), Agent.t(), term()) :: {pos_integer(), map(), nil}
  def answer(:show, %{"fleet_id" => fleet_id, "project" => project}, actor, _waiter) do
    case Budgets.project_budget(fleet_id, project, actor: actor) do
      {:ok, budget} -> {200, %{budget: budget && budget(budget)}, nil}
      {:error, error} -> refuse(fleet_id, error)
    end
  end

  def answer(:propose, %{"fleet_id" => fleet_id, "project" => project} = params, actor, _waiter),
    do:
      purchased(
        fleet_id,
        Budgets.propose_purchase(
          fleet_id,
          params["as_key"],
          project,
          params["purpose"],
          params["assist_url"],
          params["price_usdc"],
          actor: actor
        )
      )

  def answer(:decide, %{"fleet_id" => fleet_id, "purchase_id" => id} = params, actor, _waiter) do
    case Budgets.decide_purchase(
           fleet_id,
           params["as_key"],
           id,
           params["approve"],
           params["reason"],
           actor: actor
         ) do
      {:ok, %{state: :refused, refusal_code: code} = purchase}
      when code in [:over_budget, :budget_expired] ->
        {409, site_refused(purchase), nil}

      decided ->
        purchased(fleet_id, decided)
    end
  end

  def answer(:receipt, %{"fleet_id" => fleet_id, "purchase_id" => id} = params, actor, _waiter),
    do:
      purchased(
        fleet_id,
        Budgets.record_receipt(
          fleet_id,
          params["as_key"],
          id,
          params["receipt_url"],
          params["payment_tx"],
          actor: actor
        )
      )

  def answer(:result, %{"fleet_id" => fleet_id, "purchase_id" => id} = params, actor, _waiter),
    do:
      purchased(
        fleet_id,
        Budgets.record_result(
          fleet_id,
          params["as_key"],
          id,
          params["worked"],
          params["note"],
          params["evidence_url"],
          actor: actor
        )
      )

  defp purchased(_fleet_id, {:ok, purchase}), do: {200, %{purchase: purchase(purchase)}, nil}
  defp purchased(fleet_id, {:error, error}), do: refuse(fleet_id, error)

  # The approval was saved as refused: the budget couldn't cover the price, or
  # had ended; the purchase's refusal_reason says which, in numbers.
  defp site_refused(purchase) do
    Refusal.closed(refused_code(purchase.refusal_code), purchase.refusal_reason, %{
      purchase: purchase(purchase)
    })
  end

  defp refused_code(:over_budget), do: "purchase_over_budget"
  defp refused_code(:budget_expired), do: "purchase_budget_expired"

  defp budget(budget) do
    %{
      id: budget.id,
      fleet_id: budget.fleet_id,
      project: budget.project,
      sponsor_key: budget.sponsor_key,
      limit_usdc: budget.limit_usdc,
      spent_usdc: budget.spent_usdc,
      remaining_usdc: budget.remaining_usdc,
      expires_at: budget.expires_at,
      expired: budget.expired?,
      source: budget.source,
      opened_at: budget.inserted_at,
      enforced_by: "site",
      purchases: Enum.map(budget.purchases, &purchase/1)
    }
  end

  defp purchase(purchase) do
    %{
      id: purchase.id,
      budget_id: purchase.budget_id,
      purpose: purchase.purpose,
      assist_url: purchase.assist_url,
      price_usdc: purchase.price_usdc,
      state: purchase.state,
      proposed_by_key: purchase.proposed_by_key,
      proposed_at: purchase.inserted_at,
      decided_by_key: purchase.decided_by_key,
      decided_at: purchase.decided_at,
      refusal_code: purchase.refusal_code,
      refusal_reason: purchase.refusal_reason,
      receipt_url: purchase.receipt_url,
      payment_tx: purchase.payment_tx,
      bought_at: purchase.bought_at,
      worked: purchase.worked,
      result_note: purchase.result_note,
      evidence_url: purchase.evidence_url,
      checked_by_key: purchase.checked_by_key,
      checked_at: purchase.checked_at,
      verification: "not_checked"
    }
  end

  defp refuse(fleet_id, %Ash.Error.Forbidden{}) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: {403, Refusal.body("not_a_key_holder"), nil},
      else: {503, Refusal.body("ownership_refreshing"), nil}
  end

  defp refuse(_fleet_id, %{errors: errors}) do
    {status, body} = Enum.find_value(errors, &named/1) || {422, Refusal.body("budget_invalid")}
    {status, body, nil}
  end

  defp named(%BudgetError{code: code, words: words}) do
    {status, name} = Map.fetch!(@budget_errors, code)
    {status, put_in(Refusal.body(name), [:error, :message], words)}
  end

  defp named(%ClosedError{code: code} = closed) do
    status = if code == :project_archived, do: 409, else: 404

    {status,
     Refusal.closed(to_string(code), Exception.message(closed), %{
       project: closed.project,
       active: closed.active
     })}
  end

  defp named(%Ash.Error.Changes.InvalidArgument{field: field}),
    do:
      {422,
       put_in(Refusal.body("budget_invalid"), [:error, :message], "#{field} doesn't fit here.")}

  defp named(%UnknownFleetError{}), do: {404, Refusal.body("fleet_unknown")}
  defp named(%OwnershipRefreshingError{}), do: {503, Refusal.body("ownership_refreshing")}
  defp named(%NotKeyHolderError{}), do: {403, Refusal.body("not_a_key_holder")}
  defp named(%EditsRestrictedError{}), do: {403, Refusal.body("edits_restricted")}
  defp named(%CheckExpiredError{}), do: {503, Refusal.body("graph_unavailable")}
  defp named(_error), do: nil
end
