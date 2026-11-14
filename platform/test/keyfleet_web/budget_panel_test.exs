defmodule KeyfleetWeb.BudgetPanelTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Keyfleet.Actors
  alias Keyfleet.Budgets
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Projects
  alias KeyfleetWeb.BudgetPanel

  @fleet "fleet_tech_classic"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    for key <- [20, 21], do: sell(key)
    Projects.start_project!(@fleet, 20, "lab", "Lab", actor: owner(20))
    :ok
  end

  test "a member opens a budget from the panel and reads its purchases there" do
    panel = BudgetPanel.read(owner(20), @fleet, "lab")
    assert %{budget: nil} = panel

    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    params = %{"limit" => "12.5", "expires_on" => tomorrow, "source" => "Treasury funding 7"}

    assert %{budget: %{limit_usdc: 12_500_000, sponsor_key: 20}} =
             BudgetPanel.open(panel, owner(20), params)

    purchase =
      Budgets.propose_purchase!(@fleet, 21, "lab", "Fix", "https://patchbay.help/a", 2_500_000,
        actor: owner(21)
      )

    Budgets.decide_purchase!(@fleet, 20, purchase.id, true, nil, actor: owner(20))

    Budgets.record_receipt!(@fleet, 21, purchase.id, "https://patchbay.help/r", nil,
      actor: owner(21)
    )

    html =
      render_component(&BudgetPanel.panel/1, panel: BudgetPanel.read(owner(21), @fleet, "lab"))

    document = LazyHTML.from_fragment(html)

    assert text(document, "#budget-spent") == "2.5 USDC"
    assert text(document, "#budget-remaining") == "10 USDC"
    assert LazyHTML.query(document, "#budget-open") |> Enum.empty?()

    assert [href] =
             document
             |> LazyHTML.query("[data-purchase] a[href^='https://patchbay.help/r']")
             |> LazyHTML.attribute("href")

    assert href == "https://patchbay.help/r"
  end

  test "a second budget is refused while one is open, and the panel says why" do
    panel = BudgetPanel.read(owner(20), @fleet, "lab")
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    panel = BudgetPanel.open(panel, owner(20), %{"limit" => "5", "expires_on" => tomorrow})

    assert %{notice: notice, budget: %{limit_usdc: 5_000_000}} =
             BudgetPanel.open(panel, owner(21), %{"limit" => "5", "expires_on" => tomorrow})

    assert is_binary(notice)
  end

  test "someone outside the fleet sees no panel" do
    assert BudgetPanel.read(owner(99), @fleet, "lab") == nil
    assert BudgetPanel.read(nil, @fleet, "lab") == nil
  end

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

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
