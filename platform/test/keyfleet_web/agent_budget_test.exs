defmodule KeyfleetWeb.AgentBudgetTest do
  @moduledoc """
  The budget tools answer as the domain does: the answers the signed routes
  and the Claude connector share (`KeyfleetWeb.AgentTools.Budgets.Answer`),
  for two Keys taking a purchase through every step, the site's refusal of
  an approval over budget, and a Key deciding its own proposal.
  """
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Budgets
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Projects
  alias KeyfleetWeb.AgentTools.Budgets.Answer

  @fleet "fleet_tech_classic"
  @system %Actors.System{}
  @address %{"fleet_id" => @fleet, "project" => "lab"}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    for key <- [3, 20, 21], do: sell(key)
    Projects.start_project!(@fleet, 20, "lab", "Lab", actor: owner(20))

    Budgets.open_budget!(@fleet, 3, "lab", 1_000, DateTime.add(DateTime.utc_now(), 3_600), nil,
      actor: owner(3)
    )

    :ok
  end

  test "two Keys take a purchase through every step, and the budget reads as the domain's" do
    assert {200, %{purchase: %{id: id, state: :proposed}}, nil} = propose(20, 400)

    assert {200, %{purchase: %{state: :approved, decided_by_key: 21}}, nil} =
             Answer.answer(:decide, at(id, 21, %{"approve" => true}), owner(21), nil)

    receipt = %{"receipt_url" => "https://patchbay.help/r/1", "payment_tx" => "0xabc"}

    assert {200, %{purchase: %{state: :bought, verification: "not_checked"}}, nil} =
             Answer.answer(:receipt, at(id, 20, receipt), owner(20), nil)

    result = %{"worked" => false, "note" => "Retry failed"}

    assert {200, %{purchase: %{state: :failed, worked: false}}, nil} =
             Answer.answer(:result, at(id, 21, result), owner(21), nil)

    assert {200, %{budget: budget}, nil} = Answer.answer(:show, @address, owner(21), nil)
    assert %{spent_usdc: 400, remaining_usdc: 600, purchases: [%{id: ^id}]} = budget

    assert %{spent_usdc: 400, remaining_usdc: 600} =
             Budgets.project_budget!(@fleet, "lab", actor: @system)
  end

  test "an approval over budget is refused and the purchase recorded as refused" do
    {200, %{purchase: %{id: id}}, nil} = propose(20, 1_001)

    assert {409, %{error: %{code: "purchase_over_budget", details: %{purchase: purchase}}}, nil} =
             Answer.answer(:decide, at(id, 21, %{"approve" => true}), owner(21), nil)

    assert %{state: :refused, refusal_code: :over_budget} = purchase

    assert {200, %{budget: %{spent_usdc: 0, purchases: [%{state: :refused}]}}, nil} =
             Answer.answer(:show, @address, owner(20), nil)
  end

  test "a Key deciding its own proposal is refused" do
    {200, %{purchase: %{id: id}}, nil} = propose(20, 10)

    assert {403, %{error: %{code: "same_key"}}, nil} =
             Answer.answer(:decide, at(id, 20, %{"approve" => true}), owner(20), nil)
  end

  test "someone outside the fleet proposes nothing and reads no budget" do
    params =
      Map.merge(@address, %{
        "as_key" => 20,
        "purpose" => "Fix",
        "assist_url" => "https://patchbay.help/a",
        "price_usdc" => 1
      })

    assert {403, _refused, nil} = Answer.answer(:propose, params, owner(99), nil)
    assert {403, _refused, nil} = Answer.answer(:show, @address, owner(99), nil)
  end

  defp propose(key, price) do
    params =
      Map.merge(@address, %{
        "as_key" => key,
        "purpose" => "Fix the failing step",
        "assist_url" => "https://patchbay.help/assists/1",
        "price_usdc" => price
      })

    Answer.answer(:propose, params, owner(key), nil)
  end

  defp at(id, key, body),
    do: Map.merge(body, %{"fleet_id" => @fleet, "purchase_id" => id, "as_key" => key})

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
