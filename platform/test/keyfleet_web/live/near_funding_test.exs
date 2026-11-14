defmodule KeyfleetWeb.Live.NearFundingTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Actors.Human
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Fundings
  alias Keyfleet.Fundings.StubClient
  alias Keyfleet.ProposalHelpers

  @fleet "fibonacci_syndicate"
  @treasury_path "/syndicate/1/treasury"
  @member ProposalHelpers.wallet("1")
  @outsider ProposalHelpers.wallet("3")
  @elsewhere "0x" <> String.duplicate("e", 40)

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet, %{manager_address: "0x" <> String.duplicate("7", 40)})
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, [1], @member)
    # No fleet's reading is left from another test.
    Enum.each(Fleets.catalog_ids(), &Keyfleet.SharedReading.delete(KeyfleetWeb.FleetNow.key(&1)))
    # A chain that answers no reads, for the Treasury view's wallet buttons.
    Keyfleet.Chain.StubClient.put_chain(
      %{
        number: 1_000,
        hash: "0x" <> String.duplicate("f", 64),
        timestamp: DateTime.utc_now(),
        base_fee: 0
      },
      []
    )

    %{treasury: Fleets.get_fleet!(@fleet).treasury_address}
  end

  # The fleet's Treasury view, once its figures are read.
  defp open(conn) do
    KeyfleetWeb.FleetProposals.read(@fleet)
    {:ok, view, _html} = live(conn, @treasury_path)
    render_async(view, 3_000)
    view
  end

  test "a member's price is the service's quote, landing at the fleet's treasury", %{
    treasury: treasury
  } do
    price = Fundings.price_funding!(@fleet, 5_000_000, "alice.near", actor: human(@member))

    assert price.near_in_formatted == StubClient.fixture()["quote"]["amountInFormatted"]
    assert price.seconds == 24
    assert price.recipient == treasury
    assert [%{dry: true, recipient: ^treasury, usdc_amount: 5_000_000}] = StubClient.quotes()
  end

  test "Fund with NEAR records the deposit to send, and the USDC lands at the treasury", %{
    conn: conn,
    treasury: treasury
  } do
    view = open(signed_in_as(conn, @member))

    # A field naming another recipient is not one the panel reads.
    view
    |> element("#treasury-funding-form")
    |> render_submit(%{"amount" => "5", "refund_to" => "alice.near", "recipient" => @elsewhere})

    assert has_element?(view, "#treasury-funding-quote-near", "1.651313840569386417635746 NEAR")
    view |> element("#treasury-funding-fund") |> render_click()

    assert [funding] = Fundings.list_fundings!(@fleet)
    assert funding.recipient == treasury
    assert funding.usdc_amount == 5_000_000
    assert funding.deposit_address == "deposit-stub-1"
    assert funding.state == :pending_deposit
    assert Enum.all?(StubClient.quotes(), &(&1.recipient == treasury))

    assert has_element?(view, "#treasury-funding-#{funding.id}-state", "Waiting")
    assert has_element?(view, "#treasury-funding-#{funding.id}-deposit", "deposit-stub-1")
  end

  test "a funding's recipient is never an input" do
    assert {:error, %Ash.Error.Invalid{}} =
             Keyfleet.Fundings.Funding
             |> Ash.Changeset.for_create(
               :start,
               %{
                 fleet_id: @fleet,
                 usdc_amount: 5_000_000,
                 refund_to: "alice.near",
                 recipient: @elsewhere
               },
               actor: human(@member)
             )
             |> Ash.create()

    assert Fundings.list_fundings!(@fleet) == []
  end

  test "someone holding none of the fleet's Keys is refused and the service is not asked", %{
    conn: conn
  } do
    assert {:error, %Ash.Error.Forbidden{}} =
             Fundings.start_funding(@fleet, 5_000_000, "alice.near", actor: human(@outsider))

    assert {:error, %Ash.Error.Forbidden{}} =
             Fundings.price_funding(@fleet, 5_000_000, "alice.near", actor: human(@outsider))

    assert StubClient.quotes() == []
    assert Fundings.list_fundings!(@fleet) == []

    view = open(signed_in_as(conn, @outsider))
    refute has_element?(view, "#treasury-funding-form")
    assert has_element?(view, "#treasury-funding-members")
  end

  test "Refresh reads Arrived, and the receipt carries both transactions", %{
    conn: conn,
    treasury: treasury
  } do
    funding = Fundings.start_funding!(@fleet, 5_000_000, "alice.near", actor: human(@member))
    view = open(signed_in_as(conn, @member))
    assert has_element?(view, "#treasury-funding-#{funding.id}-state", "Waiting")

    StubClient.put_status(
      {:ok, %{state: :success, origin_tx: "NearTx111", destination_tx: base_tx(), raw: %{}}}
    )

    view |> element("#treasury-funding-#{funding.id}-refresh") |> render_click()

    funding = Fundings.get_funding!(@fleet, funding.id)
    assert funding.state == :success
    assert funding.origin_tx == "NearTx111"
    assert funding.destination_tx == base_tx()
    assert funding.finished_at

    receipt = "#treasury-funding-#{funding.id}-receipt"
    assert has_element?(view, "#treasury-funding-#{funding.id}-state", "Arrived")
    assert has_element?(view, ~s(#{receipt} a[href="https://nearblocks.io/txns/NearTx111"]))
    assert has_element?(view, ~s(#{receipt} a[href="https://basescan.org/tx/#{base_tx()}"]))
    assert has_element?(view, "#treasury-funding-#{funding.id}-recipient-full", treasury)

    # Anyone who sees the treasury sees the receipt.
    visitor = open(conn)
    assert has_element?(visitor, receipt)
  end

  test "Refresh before any deposit, for an address the service doesn't know yet, still reads Waiting",
       %{conn: conn} do
    funding = Fundings.start_funding!(@fleet, 5_000_000, "alice.near", actor: human(@member))
    StubClient.put_status({:error, %{reason: :not_found, message: "Deposit address not found"}})

    view = open(signed_in_as(conn, @member))
    view |> element("#treasury-funding-#{funding.id}-refresh") |> render_click()

    assert has_element?(view, "#treasury-funding-#{funding.id}-state", "Waiting")
    refute has_element?(view, "#treasury-funding-problem")
    assert Fundings.get_funding!(@fleet, funding.id).state == :pending_deposit
  end

  test "a refunded and a failed funding are recorded as such" do
    for state <- [:refunded, :failed] do
      funding = Fundings.start_funding!(@fleet, 1_000_000, "bob.near", actor: human(@member))

      StubClient.put_status(
        {:ok, %{state: state, origin_tx: "NearTx", destination_tx: nil, raw: %{}}}
      )

      funding = Fundings.refresh_funding!(funding, actor: human(@member))
      assert funding.state == state
      assert funding.destination_tx == nil
      assert funding.finished_at
    end
  end

  test "an amount over 1,000 USDC or a NEAR account in another shape is refused" do
    actor = human(@member)

    assert {:error, %Ash.Error.Invalid{}} =
             Fundings.start_funding(@fleet, 1_000_000_001, "alice.near", actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             Fundings.start_funding(@fleet, 5_000_000, "Alice Near!", actor: actor)

    assert StubClient.quotes() == []
  end

  defp base_tx, do: "0x" <> String.duplicate("ab", 32)

  defp human(wallet), do: %Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:fundings:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end
