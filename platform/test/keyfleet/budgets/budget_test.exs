defmodule Keyfleet.BudgetsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Budgets
  alias Keyfleet.Budgets.Budget
  alias Keyfleet.Budgets.Errors.BudgetError
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Projects

  @fleet "fleet_tech_classic"
  @system %Actors.System{}
  @assist "https://patchbay.help/assists/a-1"
  @receipt "https://patchbay.help/receipts/r-1"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    for key <- [3, 20, 21], do: sell(key)
    Projects.start_project!(@fleet, 20, "lab", "Lab", actor: owner(20))
    :ok
  end

  test "two Keys take a purchase through every step, and the budget counts it" do
    open!(1_000)

    purchase =
      Budgets.propose_purchase!(@fleet, 20, "lab", "Fix the failing step", @assist, 400,
        actor: owner(20)
      )

    assert %{state: :proposed, proposed_by_key: 20} = purchase
    assert figures() == {0, 1_000}

    assert %{state: :approved, decided_by_key: 21, decided_at: %DateTime{}} =
             Budgets.decide_purchase!(@fleet, 21, purchase.id, true, nil, actor: owner(21))

    assert figures() == {400, 600}

    assert %{state: :bought, receipt_url: @receipt, payment_tx: "0xabc", bought_at: %DateTime{}} =
             Budgets.record_receipt!(@fleet, 20, purchase.id, @receipt, "0xabc", actor: owner(20))

    assert figures() == {400, 600}

    assert %{state: :worked, worked: true, checked_by_key: 21, result_note: "Retry passed"} =
             Budgets.record_result!(@fleet, 21, purchase.id, true, "Retry passed", nil,
               actor: owner(21)
             )

    assert figures() == {400, 600}

    assert %{sponsor_key: 3, expired?: false, purchases: [%{state: :worked}]} =
             Budgets.project_budget!(@fleet, "lab", actor: owner(21))
  end

  test "an approval costing more than remains is refused by the site and recorded as refused" do
    open!(500)
    purchase = propose!(20, 501)

    assert %{state: :refused, refusal_code: :over_budget, decided_by_key: 21} =
             Budgets.decide_purchase!(@fleet, 21, purchase.id, true, nil, actor: owner(21))

    assert figures() == {0, 500}

    # A refused purchase takes no receipt.
    assert {:error, %{errors: [%BudgetError{code: :wrong_step}]}} =
             Budgets.record_receipt(@fleet, 20, purchase.id, @receipt, nil, actor: owner(20))
  end

  test "a Key refuses a purchase with its own reason" do
    open!(500)
    purchase = propose!(20, 100)

    assert %{state: :refused, refusal_code: :refused, refusal_reason: "Not needed"} =
             Budgets.decide_purchase!(@fleet, 21, purchase.id, false, "Not needed",
               actor: owner(21)
             )

    assert figures() == {0, 500}
  end

  test "an expired budget approves nothing" do
    budget = open!(500)
    purchase = propose!(20, 100)
    expire!(budget)

    assert %{state: :refused, refusal_code: :budget_expired} =
             Budgets.decide_purchase!(@fleet, 21, purchase.id, true, nil, actor: owner(21))

    # Nothing is proposed against it either.
    assert {:error, %{errors: [%BudgetError{code: :no_budget, field: "project"}]}} =
             Budgets.propose_purchase(@fleet, 20, "lab", "More", @assist, 1, actor: owner(20))
  end

  test "a Key never decides or checks its own proposal" do
    open!(500)
    purchase = propose!(20, 100)

    assert {:error, %{errors: [%BudgetError{code: :same_key, field: "as_key"}]}} =
             Budgets.decide_purchase(@fleet, 20, purchase.id, true, nil, actor: owner(20))

    Budgets.decide_purchase!(@fleet, 21, purchase.id, true, nil, actor: owner(21))
    Budgets.record_receipt!(@fleet, 20, purchase.id, @receipt, nil, actor: owner(20))

    assert {:error, %{errors: [%BudgetError{code: :same_key}]}} =
             Budgets.record_result(@fleet, 20, purchase.id, true, "Mine", nil, actor: owner(20))
  end

  test "only the proposing Key records the receipt" do
    open!(500)
    purchase = propose!(20, 100)
    Budgets.decide_purchase!(@fleet, 21, purchase.id, true, nil, actor: owner(21))

    assert {:error, %{errors: [%BudgetError{code: :not_proposer}]}} =
             Budgets.record_receipt(@fleet, 21, purchase.id, @receipt, nil, actor: owner(21))
  end

  # Approvals hold the budget's row while they read what it spent, so the
  # second of two approvals sees the first.
  test "two approvals that together cost more than the limit never both go through" do
    open!(1_000)
    one = propose!(20, 600)
    two = propose!(20, 600)

    assert %{state: :approved} =
             Budgets.decide_purchase!(@fleet, 21, one.id, true, nil, actor: owner(21))

    assert %{state: :refused, refusal_code: :over_budget} =
             Budgets.decide_purchase!(@fleet, 3, two.id, true, nil, actor: owner(3))

    assert figures() == {600, 400}
  end

  test "a project has one open budget at a time" do
    open!(500)

    assert {:error, %{errors: [%BudgetError{code: :budget_open, field: "project"}]}} =
             Budgets.open_budget(@fleet, 20, "lab", 100, later(), nil, actor: owner(20))
  end

  test "a stranger opens no budget, proposes nothing and reads none" do
    stranger = owner(99)

    assert {:error, %Ash.Error.Forbidden{}} =
             Budgets.open_budget(@fleet, 20, "lab", 100, later(), nil, actor: stranger)

    open!(500)

    assert {:error, %Ash.Error.Forbidden{}} =
             Budgets.propose_purchase(@fleet, 20, "lab", "Mine", @assist, 1, actor: stranger)

    assert {:error, %Ash.Error.Forbidden{}} =
             Budgets.project_budget(@fleet, "lab", actor: stranger)
  end

  test "a link that is not https is refused, naming its field" do
    open!(500)

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :assist_url}]}} =
             Budgets.propose_purchase(@fleet, 20, "lab", "Fix", "http://patchbay.help/a", 1,
               actor: owner(20)
             )
  end

  defp open!(limit),
    do:
      Budgets.open_budget!(@fleet, 3, "lab", limit, later(), "Sponsor's own USDC",
        actor: owner(3)
      )

  defp propose!(key, price),
    do: Budgets.propose_purchase!(@fleet, key, "lab", "Fix it", @assist, price, actor: owner(key))

  defp figures do
    %{spent_usdc: spent, remaining_usdc: remaining} =
      Budgets.project_budget!(@fleet, "lab", actor: @system)

    {spent, remaining}
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 3_600)

  defp expire!(%Budget{id: id}) do
    Keyfleet.Repo.query!(
      "UPDATE keyfleet_app.budgets SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp owner(key), do: %Actors.Human{human_account_id: key, wallet_addresses: [wallet(key)]}

  defp wallet(key), do: "0x" <> String.pad_leading(Integer.to_string(key), 40, "0")

  defp sell(key) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: key,
        ownership_epoch: 1,
        owner_wallet: wallet(key),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{key}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end
end
