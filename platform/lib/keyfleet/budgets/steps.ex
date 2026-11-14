defmodule Keyfleet.Budgets.Steps do
  @moduledoc """
  Takes a budget step as one of the fleet's Keys (`Keyfleet.Budgets`). The
  actor acts as the Key the same way a workspace write does
  (`Keyfleet.Graph.Checks.KeyActor`), read again in the transaction that
  saves the step, an agent's pairing held until it commits.

  Opening a budget holds the project's row first, so two opened at once
  take turns and the second finds the first. Deciding holds the budget's
  row first, then reads what it has spent, so two approvals against one
  budget take turns and the second sees the first: together they never
  spend more than the limit. Recording a receipt or a result holds the
  purchase's row. A refusal says why in words, naming the field at fault
  (`Keyfleet.Budgets.Errors.BudgetError`).
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Budgets.{Budget, Purchase}
  alias Keyfleet.Budgets.Errors.BudgetError
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Projects

  @system %Keyfleet.Actors.System{}

  @impl true
  def run(input, opts, %{actor: actor}) do
    %{fleet_id: fleet_id, as_key: key} = input.arguments
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

    with {:ok, _command} <- KeyActor.command(actor, fleet_id, key, nil, within) do
      Ash.transact([Budget, Purchase], fn ->
        held_step(actor, key, within, Keyword.fetch!(opts, :step), input.arguments)
      end)
    end
  end

  defp held_step(actor, key, within, step, %{fleet_id: fleet_id} = arguments) do
    with {:ok, _command} <- KeyActor.held_command(actor, fleet_id, key, nil, within),
         {:ok, saved} <- step(step, key, arguments),
         do: saved
  end

  defp step(:open, key, %{fleet_id: fleet_id, project: project} = arguments) do
    with {:ok, _project} <- Projects.open(fleet_id, project),
         {:ok, _held} <- Projects.locked_project(fleet_id, project, actor: @system),
         :ok <- to_come(arguments.expires_at),
         {:ok, nil} <- open_on(fleet_id, project) do
      Budget
      |> Ash.Changeset.for_create(
        :record,
        %{
          fleet_id: fleet_id,
          project: project,
          sponsor_key: key,
          limit_usdc: arguments.limit_usdc,
          expires_at: arguments.expires_at,
          source: arguments.source
        },
        actor: @system
      )
      |> Ash.create()
    else
      {:ok, %Budget{expires_at: until}} ->
        refuse(
          :budget_open,
          "project",
          "#{project} already has a budget open until #{until}. Open another once it expires."
        )

      error ->
        error
    end
  end

  defp step(:propose, key, %{fleet_id: fleet_id, project: project} = arguments) do
    case open_on(fleet_id, project) do
      {:ok, %Budget{id: budget_id}} ->
        Purchase
        |> Ash.Changeset.for_create(
          :record,
          %{
            fleet_id: fleet_id,
            budget_id: budget_id,
            purpose: arguments.purpose,
            assist_url: arguments.assist_url,
            price_usdc: arguments.price_usdc,
            proposed_by_key: key
          },
          actor: @system
        )
        |> Ash.create()

      {:ok, nil} ->
        refuse(
          :no_budget,
          "project",
          "#{project} has no open budget. A member of the fleet opens one on the project's page."
        )

      error ->
        error
    end
  end

  defp step(:decide, key, %{fleet_id: fleet_id, id: id} = arguments) do
    with {:ok, %{budget_id: budget_id}} <- purchase(fleet_id, id, :read),
         {:ok, budget} <- held_budget(budget_id),
         {:ok, purchase} <- purchase(fleet_id, id, :read),
         :ok <- at(purchase, :proposed, "decided"),
         :ok <- not_own(purchase, key, "decides") do
      decide(purchase, budget, key, arguments)
    end
  end

  defp step(:receipt, key, %{fleet_id: fleet_id, id: id} = arguments) do
    with {:ok, purchase} <- purchase(fleet_id, id, :locked),
         :ok <- at(purchase, :approved, "bought"),
         :ok <- proposer(purchase, key) do
      record(purchase, %{
        state: :bought,
        receipt_url: arguments.receipt_url,
        payment_tx: arguments.payment_tx,
        bought_at: DateTime.utc_now()
      })
    end
  end

  defp step(:result, key, %{fleet_id: fleet_id, id: id} = arguments) do
    with {:ok, purchase} <- purchase(fleet_id, id, :locked),
         :ok <- at(purchase, :bought, "checked"),
         :ok <- not_own(purchase, key, "checks") do
      record(purchase, %{
        state: if(arguments.worked, do: :worked, else: :failed),
        worked: arguments.worked,
        result_note: arguments.note,
        evidence_url: arguments.evidence_url,
        checked_by_key: key,
        checked_at: DateTime.utc_now()
      })
    end
  end

  defp decide(purchase, _budget, key, %{approve: false} = arguments),
    do: decided(purchase, key, :refused, :refused, arguments.reason)

  defp decide(purchase, budget, key, %{approve: true}) do
    cond do
      budget.expired? ->
        decided(
          purchase,
          key,
          :refused,
          :budget_expired,
          "The budget expired at #{budget.expires_at}."
        )

      purchase.price_usdc > budget.remaining_usdc ->
        decided(
          purchase,
          key,
          :refused,
          :over_budget,
          "price_usdc #{purchase.price_usdc} is more than the #{budget.remaining_usdc} the budget has left."
        )

      true ->
        decided(purchase, key, :approved, nil, nil)
    end
  end

  defp decided(purchase, key, state, code, reason) do
    record(purchase, %{
      state: state,
      decided_by_key: key,
      decided_at: DateTime.utc_now(),
      refusal_code: code,
      refusal_reason: reason
    })
  end

  defp record(purchase, attributes) do
    purchase
    |> Ash.Changeset.for_update(:record_step, attributes, actor: @system)
    |> Ash.update()
  end

  defp to_come(expires_at) do
    if DateTime.after?(expires_at, DateTime.utc_now()),
      do: :ok,
      else: refuse(:budget_expired, "expires_at", "expires_at has passed. Choose a time to come.")
  end

  defp open_on(fleet_id, project),
    do:
      Budget
      |> Ash.Query.for_read(:open_on, %{fleet_id: fleet_id, project: project}, actor: @system)
      |> Ash.read_one()

  # The budget's row is held first, then what it spent is read, so the
  # read sees every approval that held it before.
  defp held_budget(id) do
    with {:ok, budget} <-
           Budget
           |> Ash.Query.for_read(:locked, %{id: id}, actor: @system)
           |> Ash.read_one(not_found_error?: true) do
      Ash.load(budget, [:remaining_usdc, :expired?], actor: @system)
    end
  end

  defp purchase(fleet_id, id, :read) do
    case Ash.get(Purchase, id, actor: @system, not_found_error?: false) do
      {:ok, %Purchase{fleet_id: ^fleet_id} = purchase} -> {:ok, purchase}
      {:ok, _none} -> unknown()
      error -> error
    end
  end

  defp purchase(fleet_id, id, :locked) do
    Purchase
    |> Ash.Query.for_read(:locked, %{id: id}, actor: @system)
    |> Ash.read_one()
    |> case do
      {:ok, %Purchase{fleet_id: ^fleet_id} = purchase} -> {:ok, purchase}
      {:ok, _none} -> unknown()
      error -> error
    end
  end

  defp unknown, do: refuse(:purchase_unknown, "id", "This fleet has no purchase by that id.")

  defp at(%{state: state}, state, _done), do: :ok

  defp at(%{state: state}, _wanted, done),
    do: refuse(:wrong_step, "id", "This purchase is #{state}, so it can't be #{done} now.")

  defp not_own(%{proposed_by_key: key}, key, does),
    do:
      refuse(
        :same_key,
        "as_key",
        "Key #{key} proposed this purchase. A different Key #{does} it."
      )

  defp not_own(_purchase, _key, _does), do: :ok

  defp proposer(%{proposed_by_key: key}, key), do: :ok

  defp proposer(%{proposed_by_key: proposer}, _key),
    do:
      refuse(
        :not_proposer,
        "as_key",
        "Key #{proposer} proposed this purchase. Only that Key records its receipt."
      )

  defp refuse(code, field, words),
    do: {:error, BudgetError.exception(code: code, field: field, words: words)}
end
