defmodule KeyfleetWeb.Live.ProposalsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures
  alias RegentChain.Call

  @fleet "fibonacci_syndicate"
  @list "/app/fleets/fibonacci_syndicate/proposals"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @voter ProposalHelpers.wallet("e")
  @holder ProposalHelpers.wallet("1")
  @votes "0x" <> String.duplicate("9", 40)
  @fleet_contract "0x" <> String.duplicate("7", 40)
  @rule KeyfleetWeb.ProposalsLive.approval_rule()

  setup do
    Fleets.bootstrap_catalog!()

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: @fleet_contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        usdc_address: @usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )

    :ok
  end

  test "anyone can read every proposal and where each one stands", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..7)

    ProposalHelpers.proposal!(@fleet, 1, text: "Hire a designer", text_bytes: 15)
    ProposalHelpers.proposal!(@fleet, 2)
    votes!(2, true: [1, 2, 3, 4])
    ProposalHelpers.proposal!(@fleet, 3)
    votes!(3, true: [1, 2, 3], false: [4])
    ProposalHelpers.proposal!(@fleet, 4, kind: :pay)
    votes!(4, true: [1, 2, 3, 4])
    ProposalHelpers.execution!(@fleet, 4, @voter)
    ProposalHelpers.proposal!(@fleet, 5, kind: :autolaunch)
    votes!(5, true: [1, 2, 3, 4])
    ProposalHelpers.execution!(@fleet, 5, @voter)

    {:ok, view, html} = live(conn, @list)

    assert has_element?(view, ".proposals-rule", @rule)
    refute html =~ "Vote counts are catching up."

    assert cards(view) == [
             {"5", "Launch", "Launched"},
             {"4", "Payment from shared money", "Paid"},
             {"3", "Decision", "Open"},
             {"2", "Decision", "Approved"},
             {"1", "Decision", "Open"}
           ]

    assert has_element?(view, ~s([data-proposal="1"]), "Hire a designer")
    assert has_element?(view, ~s([data-proposal="3"]), "3 yes, 1 no, of 7 keys sold")

    view |> element(~s([data-proposal="2"] a)) |> render_click()
    assert_patch(view, "/app/fleets/#{@fleet}/proposals/2")
  end

  # A key may vote again, and only its latest vote counts; a key sold later
  # adds to the keys a proposal needs more than half of.
  test "a key's latest vote counts, and a key sold later can take a passed proposal back to voting",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)
    votes!(1, true: [1], false: [2])
    votes!(1, true: [2])

    {:ok, view, _html} = live(conn, "#{@list}/1")
    {:ok, list, _html} = live(conn, @list)
    assert has_element?(view, "#proposal-status", "Approved")
    assert has_element?(view, "#proposal-yes", "2 keys")
    assert has_element?(view, "#proposal-no", "0 keys")
    assert has_element?(view, "#proposal-keys-sold", "3 keys")

    ProposalHelpers.keys_sold!(@fleet, [4])

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:proposals_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "#proposal-status", "Open") end)
    assert has_element?(view, "#proposal-keys-sold", "4 keys")

    assert shows?(fn ->
             has_element?(list, ~s([data-proposal="1"]), "2 yes, 0 no, of 4 keys sold")
           end)
  end

  test "a withdrawn vote counts for neither side and is listed as withdrawn", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)
    votes!(1, true: [1, 2], false: [3])
    votes!(1, nil: [2, 3])

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-status", "Open")
    assert has_element?(view, "#proposal-yes", "1 key")
    assert has_element?(view, "#proposal-no", "0 keys")
    assert [yes, no, withdrawn] = votes(view)
    assert yes =~ ~r/^Yes.*with keys 1, 2$/
    assert no =~ ~r/^No.*with key 3$/
    assert withdrawn =~ ~r/^Withdrawn.*with keys 2, 3$/
  end

  test "a proposal's page shows its text, its outcome and every vote, fifty at a time", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..120)
    ProposalHelpers.proposal!(@fleet, 1, text: "Hire a designer\nfor the launch", text_bytes: 30)
    for token_id <- 1..51, do: ProposalHelpers.vote!(@fleet, 1, @voter, true, [token_id])

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert has_element?(view, "#proposal-status", "Open")
    # Its line breaks are kept as written.
    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#proposal-text")
           |> LazyHTML.text() ==
             "Hire a designer\nfor the launch"

    assert has_element?(view, "#proposal-yes", "51 keys")
    assert has_element?(view, ".proposals-rule", @rule)
    assert length(votes(view)) == 50
    assert hd(votes(view)) =~ "with key 1"

    view |> element("#proposal-more-votes") |> render_click()
    assert [only] = votes(view)
    assert only =~ "with key 51"

    view |> element("#proposal-first-votes") |> render_click()
    assert length(votes(view)) == 50
  end

  test "a payment names what it pays and to whom", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    ProposalHelpers.proposal!(@fleet, 1,
      kind: :pay,
      asset: @usdc,
      amount: Decimal.new(12_500_000)
    )

    ProposalHelpers.proposal!(@fleet, 2,
      kind: :pay,
      asset: ProposalHelpers.wallet("c"),
      amount: Decimal.new(1_234)
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert fields(view, "#proposal-payment div") == [
             {"Amount", "12.5 USDC"},
             {"Paid to", ProposalHelpers.wallet("b")}
           ]

    refute has_element?(view, "#proposal-payment .proposals-token")

    # An asset whose token has not been asked yet is shown as the chain
    # holds it, with the token's address.
    other_token = ProposalHelpers.wallet("c")
    {:ok, other, _html} = live(conn, "#{@list}/2")

    assert amount(other, "#proposal-payment div:first-child dd") ==
             {"1,234 in the smallest units of token 0xcccc..cccc", other_token}

    # Once the token has told its symbol and decimals, it is named, and its
    # address is still beside it.
    ProposalHelpers.asset_details!(@fleet, other_token, "WETH", 18)
    {:ok, named, _html} = live(conn, "#{@list}/2")

    assert amount(named, "#proposal-payment div:first-child dd") ==
             {"0.000000000000001234 WETH 0xcccc..cccc", other_token}
  end

  # Only the fleet's own USDC, known by its address, is shown without one. A
  # token anywhere else that calls itself USDC always has its address beside
  # every amount of it.
  test "a token calling itself USDC is shown with its address", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    fake = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    ProposalHelpers.asset_details!(@fleet, fake, "USDC", 6)

    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, asset: fake, amount: 2_000_000)
    ProposalHelpers.proposal!(@fleet, 2, kind: :pay, asset: @usdc, amount: 2_000_000)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, free_capital: 1_000_000),
      balance(fake, free_capital: 1_000_000, backed: 3_000_000)
    ])

    ProposalHelpers.income_receipt!(@fleet, asset: fake)
    ProposalHelpers.budget_payment!(@fleet, asset: fake)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert amount(view, "#proposal-payment div:first-child dd") == {"2 USDC 0xdddd..dddd", fake}

    {:ok, view, _html} = live(conn, "#{@list}/2")
    assert amount(view, "#proposal-payment div:first-child dd") == {"2 USDC", nil}

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{fake}'] div") == [
             {"Shared money", "1 USDC 0xdddd..dddd"},
             {"Set aside for key holders", "3 USDC 0xdddd..dddd"}
           ]

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", "1 USDC"},
             {"Set aside for key holders", "0 USDC"}
           ]

    tokens =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#proposals-income .proposals-token, #proposals-payments .proposals-token"
      )
      |> Enum.map(&{text(&1), &1 |> LazyHTML.attribute("title") |> hd()})

    assert tokens == List.duplicate({"0xdddd..dddd", fake}, 2)
  end

  # A token that will not tell its symbol or its decimals is never guessed at.
  test "an amount in a token that doesn't say what it is shows as the chain holds it", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)

    for {number, character, symbol, decimals} <- [{1, "c", nil, 18}, {2, "d", "ODD", nil}] do
      asset = ProposalHelpers.wallet(character)
      ProposalHelpers.asset_details!(@fleet, asset, symbol, decimals)
      ProposalHelpers.proposal!(@fleet, number, kind: :pay, asset: asset, amount: 1_234_000)

      {:ok, view, _html} = live(conn, "#{@list}/#{number}")

      assert amount(view, "#proposal-payment div:first-child dd") ==
               {"1,234,000 in the smallest units of token #{RegentFormat.short_address(asset)}",
                asset}
    end

    # The fleet's USDC is known by its address even before its token has
    # said what it is.
    ProposalHelpers.proposal!(@fleet, 3, kind: :pay, asset: @usdc, amount: 1_234_000)
    {:ok, view, _html} = live(conn, "#{@list}/3")

    assert amount(view, "#proposal-payment div:first-child dd") ==
             {"1,234,000 in USDC’s smallest units", nil}
  end

  # The contract holds any uint256, which is shown to the last digit.
  test "the largest amount the contract can hold is shown whole", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    max = 2 ** 256 - 1

    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, asset: @usdc, amount: Decimal.new(max))

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, free_capital: max, backed: max)
    ])

    whole =
      "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584," <>
        "007,913,129.639935 USDC"

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-payment", whole)

    {:ok, list, _html} = live(conn, @list)

    assert fields(list, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", whole},
             {"Set aside for key holders", whole}
           ]
  end

  test "a launch shows its five fields exactly as proposed, once they have been read", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    proposal = ProposalHelpers.proposal!(@fleet, 1, kind: :autolaunch)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-launch-pending", "Launch details are still being read.")
    refute has_element?(view, "#proposal-launch")

    ProposalHelpers.launch_envelope!(proposal,
      name: "Cascade  Research",
      description: "Line one\nLine <two>",
      required_regent_raised: Decimal.new("250000500000000000000000")
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert fields(view, "#proposal-launch div") == [
             {"Name", "Cascade  Research"},
             {"Symbol", "CSR"},
             {"Description", "Line one\nLine <two>"},
             {"Website", "https://example.test"},
             {"Image", "ipfs://cascade"},
             {"REGENT to raise", "250,000.5 REGENT"}
           ]
  end

  describe "a launch's plan" do
    setup do
      ChainHelpers.seed_cursor!(@fleet)
      WorkspaceFixtures.open_log(@fleet)
      :ok
    end

    test "names the plan version the launch points to, and what it says", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(1, digest(plan, 1))

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert has_element?(
               view,
               ~s|#proposal-plan-version a[href="/app/fleets/#{@fleet}/workspace/launch_card%231"]|,
               "Cascade Research"
             )

      assert text(view, "#proposal-plan-version") ==
               "This launch points to Cascade Research, version 1."

      assert fields(view, "#proposal-plan-fields div") == [
               {"Who it’s for", "Funds that read filings"},
               {"What we offer", "A weekly brief"},
               {"Who does what afterwards", "Key 17 writes the brief"}
             ]

      assert text(view, "#proposal-plan-benefits") ==
               "Who benefits: the fleet’s keys receive all of the launch’s income, and its shared money " <>
                 "keeps the REGENT the auction raises beyond what goes into the pool, and the " <>
                 "launched tokens as they vest."

      refute has_element?(view, "#proposal-plan-mismatch")
      refute has_element?(view, "#proposal-plan-changed")
      refute has_element?(view, "#proposal-plan-archived")
    end

    test "says when the plan has changed or been archived since", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(1, digest(plan, 1))

      # Archiving alone leaves what the plan says as it was.
      WorkspaceFixtures.archive(@fleet, plan)
      {:ok, view, _html} = live(conn, "#{@list}/1")
      assert has_element?(view, "#proposal-plan-archived", "This plan has since been archived.")
      refute has_element?(view, "#proposal-plan-changed")

      other = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(2, digest(other, 1))
      WorkspaceFixtures.edit(@fleet, other, %{"what_we_sell" => "A daily brief"})

      {:ok, view, _html} = live(conn, "#{@list}/2")

      assert text(view, "#proposal-plan-changed") =~
               "The plan has changed since; this proposal carries version 1."

      assert text(view, "#proposal-plan-version") =~ "version 1."
      assert {"What we offer", "A weekly brief"} in fields(view, "#proposal-plan-fields div")
      refute has_element?(view, "#proposal-plan-archived")
    end

    test "lists in plain words the launch details that differ from the plan", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())

      launch!(1, digest(plan, 1),
        name: "Cascade Research Two",
        required_regent_raised: Decimal.new("250000000000000000000000")
      )

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert text(view, "#proposal-plan-mismatch") ==
               "These launch details differ from the plan: name, the REGENT to raise."
    end

    test "is not shown for a launch that points to no plan the workspace has", %{conn: conn} do
      launch!(1, "0x" <> String.duplicate("e", 64))
      launch!(2, nil)

      for number <- [1, 2] do
        {:ok, view, _html} = live(conn, "#{@list}/#{number}")

        assert has_element?(
                 view,
                 "#proposal-no-plan",
                 "This launch doesn’t point to a plan in the workspace."
               )

        refute has_element?(view, "#proposal-plan-version")
      end

      ProposalHelpers.proposal!(@fleet, 3)
      {:ok, view, _html} = live(conn, "#{@list}/3")
      refute has_element?(view, "#proposal-plan")
    end

    test "a launch can start from any plan that has all six launch details", %{conn: conn} do
      ready = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      WorkspaceFixtures.edit(@fleet, ready, %{"title" => "Cascade Research, revised"})
      WorkspaceFixtures.create(@fleet, "launch_card", plan_data(%{"image" => nil}))
      WorkspaceFixtures.create(@fleet, "launch_card", plan_data(%{"symbol" => ""}))
      archived = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      WorkspaceFixtures.archive(@fleet, archived)

      {:ok, view, _html} = live(conn, @list)

      assert view |> element("#propose-launch-plan") |> render() |> options() == [
               {"", "Don’t use a plan"},
               {digest(ready, 2), "Cascade Research, revised, version 2"}
             ]

      assert has_element?(
               view,
               ~s|#propose-launch-plan option[value="#{digest(ready, 2)}"][data-name="Cascade Research"][data-symbol="CSR"][data-raise="250000.5"]|
             )

      # Going back to the page shows the form as new, never a plan the
      # browser remembers with its details and digest gone.
      assert has_element?(view, ~s|#propose-launch-plan[autocomplete="off"]|)

      assert has_element?(
               view,
               ~s|#propose-launch-digest[type="hidden"][name="digest"][value=""][autocomplete="off"]|
             )

      refute has_element?(
               view,
               ~s|#propose-launch-fields input[name="digest"]:not([type="hidden"])|
             )

      assert pressable?(view, "propose", ["#propose-launch-button"])
    end
  end

  test "while votes are still being read the page says so", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    ProposalHelpers.proposal!(@fleet, 1)

    for path <- [@list, "#{@list}/1"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#proposals-catching-up", "Vote counts are catching up.")
    end
  end

  test "a fleet or proposal that isn't there says so, and a name that can't be one is not found",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals")
    assert html =~ "This fleet doesn’t exist."

    {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals/1")
    assert html =~ "This fleet doesn’t exist."

    {:ok, view, html} = live(conn, "#{@list}/9")
    assert html =~ "There is no proposal 9 in this fleet yet."
    assert has_element?(view, "#proposal-missing a[href='#{@list}']")

    {:ok, _view, html} = live(conn, @list)
    assert html =~ "No proposals have been made yet."

    for path <- [
          "#{@list}/0",
          "#{@list}/01",
          "#{@list}/one",
          "#{@list}/#{String.duplicate("9", 19)}",
          "#{@list}?before=0",
          "#{@list}?before=x",
          "#{@list}/1?votes_after=-1"
        ] do
      assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, path) end
    end
  end

  test "proposals are listed twenty at a time, newest first", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    for number <- 1..21, do: ProposalHelpers.proposal!(@fleet, number)

    {:ok, view, _html} = live(conn, @list)
    assert Enum.map(cards(view), &elem(&1, 0)) == Enum.map(21..2//-1, &to_string/1)
    refute has_element?(view, "#proposals-newest")

    view |> element("#proposals-older") |> render_click()
    assert Enum.map(cards(view), &elem(&1, 0)) == ["1"]
    refute has_element?(view, "#proposals-older")

    view |> element("#proposals-newest") |> render_click()
    assert length(cards(view)) == 20
  end

  test "a notice that votes were recorded has an open page read them again", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    {:ok, list, _html} = live(conn, @list)
    assert has_element?(view, "#proposal-yes", "0 keys")

    ProposalHelpers.vote!(@fleet, 1, @voter, true, [1, 2])
    assert has_element?(view, "#proposal-yes", "0 keys")

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:proposals_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "#proposal-yes", "2 keys") end)
    assert shows?(fn -> has_element?(list, ~s([data-proposal="1"]), "2 yes, 0 no") end)
  end

  test "a notice that balances were read has an open page show them", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, free_capital: 3_000_000)])
    assert has_element?(view, "#proposals-budget-pending")

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:balances_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "[data-asset='#{@usdc}']", "3 USDC") end)
  end

  test "the shared money shows what the fleet holds", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    as_of = ~U[2026-09-20 12:00:00Z]
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    ProposalHelpers.treasury_reading!(
      @fleet,
      [
        balance(@usdc, free_capital: 100_000_000, backed: 30_000_000),
        balance(weth, free_capital: 2_000_000_000_000_000_000)
      ],
      block_time: as_of,
      protocol_share_owed: Decimal.new(2_500_000)
    )

    ProposalHelpers.income_receipt!(@fleet, asset: @usdc)
    ProposalHelpers.budget_payment!(@fleet, asset: @usdc)

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", "100 USDC"},
             {"Set aside for key holders", "30 USDC"}
           ]

    assert fields(view, "[data-asset='#{weth}'] div") == [
             {"Shared money", "2 WETH 0xcccc..cccc"},
             {"Set aside for key holders", "0 WETH 0xcccc..cccc"}
           ]

    assert fields(view, "#proposals-held div") == [{"Set aside for REGENT stakers", "2.5 USDC"}]

    assert has_element?(
             view,
             "#proposals-budget-as-of",
             "Figures as of 20 September 2026 at 12:00 UTC."
           )

    assert has_element?(view, "#proposals-income li", "10 USDC paid to key holders")

    assert has_element?(view, "#proposals-payments li", "5 USDC")
    assert has_element?(view, "#proposals-payments li", "to #{ProposalHelpers.wallet("b")}")
  end

  test "the shared money says what it doesn't know yet", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    {:ok, view, _html} = live(conn, @list)

    assert has_element?(
             view,
             "#proposals-budget-pending",
             "The shared money’s figures are still being read."
           )

    assert has_element?(view, "#proposals-no-income", "No income yet.")

    assert has_element?(
             view,
             "#proposals-no-payments",
             "Nothing has been paid from the shared money yet."
           )

    ProposalHelpers.treasury_reading!(
      @fleet,
      [balance(@usdc, free_capital: 50_000_000)],
      block_time: ~U[2026-09-20 12:00:00Z],
      cascade_reserve: Decimal.new(7_000_000)
    )

    for _payment <- 1..21, do: ProposalHelpers.budget_payment!(@fleet, asset: @usdc)

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", "50 USDC"},
             {"Set aside for key holders", "0 USDC"}
           ]

    assert fields(view, "#proposals-held div") == [
             {"Held for the next level", "7 USDC"},
             {"Set aside for REGENT stakers", "0 USDC"}
           ]

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#proposals-payments li")
           |> Enum.count() == 20

    assert render(view) =~ "Earlier payments are not shown here."
  end

  # Until a fleet is on chain it has no shared money, and its page says nothing
  # about one.
  test "a fleet not yet on chain shows no shared money", %{conn: conn} do
    {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_classic/proposals")
    assert has_element?(view, "#proposals-page")
    refute has_element?(view, "#proposals-budget")
    refute has_element?(view, "[data-fleet-action]")
    refute html =~ "Shared money"
    refute html =~ "shared money"
  end

  test "the fleet's page leads to its proposals", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")
    assert has_element?(view, "#fleet-proposals-link[href='#{@list}']", "Proposals")
  end

  # Every wallet button reaches the wallet whatever the page shows: what the
  # page knows is said beside it, and the contract decides.
  test "the vote buttons take every press, however the vote stands", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)

    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.vote!(@fleet, 1, @holder, true, [2])
    ProposalHelpers.proposal!(@fleet, 2)
    votes!(2, true: [1, 2])
    ProposalHelpers.proposal!(@fleet, 3, kind: :pay)
    votes!(3, true: [1, 2])
    ProposalHelpers.execution!(@fleet, 3, @voter)
    holder = signed_in_as(conn, @holder)

    # Open, by someone who has voted already.
    {:ok, view, _html} = live(holder, "#{@list}/1")
    assert votes_pressable?(view)
    assert has_element?(view, "#proposal-vote-closed[hidden]")

    # Approved: a key can still change its vote until it is carried out.
    {:ok, view, _html} = live(holder, "#{@list}/2")
    assert has_element?(view, "#proposal-status", "Approved")
    assert votes_pressable?(view)
    assert has_element?(view, "#proposal-vote-closed[hidden]")

    # Carried out.
    {:ok, view, _html} = live(holder, "#{@list}/3")
    assert has_element?(view, "#proposal-status", "Paid")
    assert votes_pressable?(view)

    assert has_element?(
             view,
             "#proposal-vote-closed:not([hidden])",
             "It has already been carried out"
           )

    # Signed out.
    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert votes_pressable?(view)
  end

  # The keys typed are the keys voted with; the server builds each of the
  # three steps for the signed-in wallet before anyone presses.
  test "voting builds yes, no and withdraw for the keys typed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)

    assert text(view, "#proposal-vote-action-line") ==
             "Type the numbers of the keys to use, like 3, 7, 12."

    view |> form("#proposal-vote-action-form", keys: "1, 3") |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposal-vote-action",
      review: %{signer: @holder, steps: [yes, no, withdraw]}
    })

    assert {yes.step, yes.to, yes.data} ==
             {"yes", @votes, Call.encode("vote(uint256,uint256[],bool)", [1, [1, 3], true])}

    assert {no.step, no.data} ==
             {"no", Call.encode("vote(uint256,uint256[],bool)", [1, [1, 3], false])}

    assert {withdraw.step, withdraw.data} ==
             {"withdraw", Call.encode("withdrawVote(uint256,uint256[])", [1, [1, 3]])}

    assert text(view, "#proposal-vote-action-line") ==
             "Voting, changing or withdrawing uses keys 1, 3. Each key is one vote."

    assert text(view, "#proposal-vote-action-from") == "Sending from 0x1111..1111 on Base."
  end

  # A vote the contract turns down says why it may have been, and the
  # buttons stay to press again.
  test "a vote that doesn't go through says why it may not have", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)
    view |> form("#proposal-vote-action-form", keys: "2") |> render_change()
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [yes | _]} = review})

    hash = "0x" <> String.duplicate("4", 64)
    TestChainNode.land!(hash, review, yes, "0x0")

    view
    |> with_target("#proposal-vote-action")
    |> render_hook("step_sent", %{
      "review_id" => review.id,
      "step" => "yes",
      "transaction_hash" => hash
    })

    render_async(view)

    assert has_element?(
             view,
             "#proposal-vote-action-sent li[data-state=reverted] strong",
             "Vote yes, key 2"
           )

    assert text(view, "#proposal-vote-action-sent span") =~
             "This vote didn’t go through and nothing changed."

    assert votes_pressable?(view)
  end

  test "carrying a proposal out takes every press, whatever it says about the outcome", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, [1])

    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.proposal!(@fleet, 2)
    ProposalHelpers.proposal!(@fleet, 3, kind: :pay)
    # The fleet's last launch, created in block 10, failed: a launch proposal
    # that opened in or before that block will be refused, one opened after
    # it won't.
    ProposalHelpers.proposal!(@fleet, 4, kind: :autolaunch, opened_block: 10)
    ProposalHelpers.proposal!(@fleet, 5, kind: :autolaunch)
    ProposalHelpers.proposal!(@fleet, 6, kind: :autolaunch, opened_block: 11)
    for number <- 2..6, do: votes!(number, true: [1])
    ProposalHelpers.execution!(@fleet, 3, @voter)
    ProposalHelpers.execution!(@fleet, 5, @voter)
    ProposalHelpers.treasury_reading!(@fleet, [], failed_launch_block: 10)

    {:ok, list, _html} = live(conn, @list)
    assert {"4", "Launch", "Proposed before the last launch"} in cards(list)
    assert {"6", "Launch", "Approved"} in cards(list)

    for {number, status, word, note} <- [
          {1, "Open", "Record the decision", "Yes votes aren’t yet more than half"},
          {2, "Approved", "Record the decision", nil},
          {3, "Paid", "Make the payment", "It has already been carried out"},
          {4, "Proposed before the last launch", "Start the launch",
           "This launch was proposed before the fleet’s last launch, which didn’t succeed, " <>
             "so carrying it out will be refused. Propose it again to try another launch."},
          {5, "Launched", "Start the launch", "It has already been carried out"},
          {6, "Approved", "Start the launch", nil}
        ] do
      {:ok, view, _html} = live(conn, "#{@list}/#{number}")
      assert has_element?(view, "#proposal-status", status), "proposal #{number}"
      assert pressable?(view, "carry_out", ["#proposal-carry-out-button"]), "proposal #{number}"
      assert has_element?(view, "#proposal-carry-out-button", word)

      shown = shown_notes(view, "#proposal-carry-out [id^=proposal-carry-out-note-]")

      if note do
        assert [shown_note] = shown, "proposal #{number}"
        assert shown_note =~ note
      else
        assert shown == [], "proposal #{number}"
      end
    end

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/2")
    active!(view, "#proposal-carry-out-action", @holder)

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposal-carry-out-action",
      review: %{steps: [%{step: "carry_out", to: @votes} = carry_out]}
    })

    assert carry_out.data == Call.encode("execute(uint256)", [2])
  end

  # A carried-out payment's match: every key that didn't vote yes collects
  # the same amount, paid to whoever holds it now.
  test "a carried-out payment offers its match to collect", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    ProposalHelpers.proposal!(@fleet, 1, kind: :pay)
    votes!(1, true: [1, 2])
    execution = ProposalHelpers.execution!(@fleet, 1, @voter)
    ProposalHelpers.proposal!(@fleet, 2)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-match[hidden]")
    refute has_element?(view, "#proposal-match-pending[hidden]")
    assert pressable?(view, "collect", ["#proposal-collect-button"])

    ProposalHelpers.budget_payment!(@fleet,
      asset: @usdc,
      share: Decimal.new(2_500_000),
      transaction_hash: execution.transaction_hash
    )

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")

    assert text(view, "#proposal-match") =~
             "Every key sold when this was paid that didn’t vote yes can collect 2.5 USDC"

    assert has_element?(view, "#proposal-match-pending[hidden]")

    active!(view, "#proposal-collect-action", @holder)
    view |> form("#proposal-collect-action-form", keys: "3") |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposal-collect-action",
      review: %{steps: [%{step: "collect", to: @votes} = collect]}
    })

    assert collect.data == Call.encode("collect(uint256,uint256[])", [1, [3]])
    assert text(view, "#proposal-collect-action-line") == "Collects the match of key 3."

    # Nothing to collect on a proposal that isn't a payment.
    {:ok, view, _html} = live(conn, "#{@list}/2")
    refute has_element?(view, "#proposal-collect")
  end

  test "proposing and letting another wallet vote take every press, signed in or not", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    odd = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, free_capital: 1),
      balance(weth, free_capital: 1),
      balance(odd, [])
    ])

    buttons = [
      {"propose", "#propose-decision-button"},
      {"propose", "#propose-payment-button"},
      {"propose", "#propose-launch-button"},
      {"delegate", "#voting-delegate-button"},
      {"clear", "#voting-delegate-clear"}
    ]

    {:ok, view, _html} = live(conn, @list)

    for {step, button} <- buttons, do: assert(pressable?(view, step, [button]), button)

    assert view |> element("#propose-payment-asset") |> render() |> options() == [
             {@usdc, "USDC"},
             {weth, "WETH 0xcccc..cccc"},
             {odd, "Token 0xdddd..dddd, in its smallest units"},
             {"other", "Another token (paste its address)"}
           ]

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    for {step, button} <- buttons, do: assert(pressable?(view, step, [button]), button)
  end

  # Each proposal is built on the server from the form as typed, for the
  # signed-in wallet, and the page has it before anyone presses.
  test "a proposal is built from the form as typed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)
    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, []), balance(weth, [])])
    recipient = ProposalHelpers.wallet("b")
    code = String.duplicate("ab", 32)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)

    active!(view, "#propose-decision-action", @holder)

    view
    |> form("#propose-decision-action-form", key: "7", text: "Hire a designer", digest: code)
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-decision-action",
      review: %{steps: [decision]}
    })

    assert decision.data ==
             Call.encode("proposeDecision(uint256,string,bytes32)", [
               7,
               "Hire a designer",
               "0x" <> code
             ])

    assert text(view, "#propose-decision-action-line") == "Proposes this decision with key 7."

    active!(view, "#propose-payment-action", @holder)

    view
    |> form("#propose-payment-action-form",
      key: "7",
      asset: weth,
      amount: "1.5",
      recipient: recipient,
      text: "Pay the designer"
    )
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-payment-action",
      review: %{steps: [payment]}
    })

    assert payment.data ==
             Call.encode("proposePay(uint256,address,uint256,address,string,bytes32)", [
               7,
               weth,
               1_500_000_000_000_000_000,
               recipient,
               "Pay the designer",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-payment-action-line") ==
             "Proposes paying 1.5 WETH (0xcccc..cccc) to 0xbbbb..bbbb, with key 7."

    # Another token, pasted, is paid in its smallest units.
    pasted = ProposalHelpers.wallet("5")

    view
    |> form("#propose-payment-action-form", asset: "other", other_asset: pasted, amount: "250")
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-payment-action",
      review: %{steps: [pasted_payment]}
    })

    assert pasted_payment.data ==
             Call.encode("proposePay(uint256,address,uint256,address,string,bytes32)", [
               7,
               pasted,
               250,
               recipient,
               "Pay the designer",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-payment-action-line") ==
             "Proposes paying 250 in the smallest units of token 0x5555..5555 to 0xbbbb..bbbb, with key 7."

    view
    |> form("#propose-payment-action-form", other_asset: "0x12")
    |> render_change()

    assert text(view, "#propose-payment-action-line") ==
             "The token isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers."

    active!(view, "#propose-launch-action", @holder)

    view
    |> form("#propose-launch-action-form",
      key: "7",
      name: "Cascade Research",
      symbol: "CSR",
      description: "Research the fleet funds",
      website: "https://example.test",
      image: "ipfs://cascade",
      raise: "250,000.5"
    )
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-launch-action",
      review: %{steps: [launch]}
    })

    assert launch.data ==
             Call.encode(
               "proposeAutolaunch(uint256,(string,string,string,string,string,uint128,bytes32))",
               [
                 7,
                 {"Cascade Research", "CSR", "Research the fleet funds", "https://example.test",
                  "ipfs://cascade", 250_000_500_000_000_000_000_000,
                  "0x" <> String.duplicate("0", 64)}
               ]
             )

    assert text(view, "#propose-launch-action-line") ==
             "Proposes a launch that raises 250,000.5 REGENT, with key 7."
  end

  test "letting another wallet vote is built for the wallet typed, and clearing for your own", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    delegate = ProposalHelpers.wallet("d")

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    active!(view, "#voting-delegate-action", @holder)

    assert text(view, "#voting-delegate-action-line") ==
             "Type the wallet that may vote for you, or stop any other wallet voting for you."

    # Clearing needs nothing typed.
    assert_push_event(view, "onchain-steps:review", %{
      component_id: "voting-delegate-action",
      review: %{steps: [%{step: "clear"}]}
    })

    view |> form("#voting-delegate-action-form", delegate: delegate) |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "voting-delegate-action",
      review: %{steps: steps}
    })

    assert Map.new(steps, &{&1.step, &1.data}) == %{
             "delegate" => Call.encode("setVotingDelegate(address)", [delegate]),
             "clear" => Call.encode("setVotingDelegate(address)", [@holder])
           }
  end

  # Skill rule 3: with a wallet open that the account doesn't link, the
  # figures stay on the account's own wallet and nothing is given to send.
  test "a wallet the account doesn't link gets nothing to send, and the note names both", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1)
    stranger = ProposalHelpers.wallet("b")

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", stranger)
    view |> form("#proposal-vote-action-form", keys: "1") |> render_change()

    refute_push_event(view, "onchain-steps:review", %{review: %{}})

    assert text(view, "#proposal-vote-action-mismatch") ==
             "You're signed in with 0x1111..1111, but your wallet app has 0xbbbb..bbbb open. " <>
               "Switch to a wallet on your account to send from here."

    assert has_element?(view, "#proposal-vote-action-from[hidden]")
    assert votes_pressable?(view)

    # Signed out: nothing is built, and every group of buttons is still there.
    {:ok, view, _html} = live(conn, "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)
    refute_push_event(view, "onchain-steps:review", %{review: %{}})
    assert has_element?(view, "#proposal-vote-action-line[hidden]")
    assert has_element?(view, "#proposal-vote-action-mismatch[hidden]")

    view
    |> with_target("#proposal-vote-action")
    |> render_hook("step_failed", %{"step" => "yes", "reason" => "wallet_unavailable"})

    assert text(view, "#proposal-vote-action-press-note") ==
             "Sign in to send this. Nothing was sent."
  end

  test "sending the stakers their share takes every press, owed or not", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    # Before the shared money has been read.
    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")
    assert pressable?(view, "send", ["#proposals-send-share"])
    assert has_element?(view, "#proposals-nothing-owed[hidden]")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])])
    {:ok, view, _html} = live(conn, @list)
    assert fields(view, "#proposals-held div") == [{"Set aside for REGENT stakers", "0 USDC"}]
    assert pressable?(view, "send", ["#proposals-send-share"])
    refute has_element?(view, "#proposals-nothing-owed[hidden]")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])],
      protocol_share_owed: Decimal.new(2_500_000)
    )

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    assert pressable?(view, "send", ["#proposals-send-share"])
    assert has_element?(view, "#proposals-nothing-owed[hidden]")

    active!(view, "#proposals-stakers-share", @holder)

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposals-stakers-share",
      review: %{steps: [%{step: "send", to: @fleet_contract} = send]}
    })

    assert send.data == Call.encode("sendProtocolShare()", [])
  end

  # Every launch detail and three of the plan's other fields filled in.
  defp plan_data(attrs \\ %{}) do
    Map.merge(
      %{
        "title" => "Cascade Research",
        "who_we_serve" => "Funds that read filings",
        "what_we_sell" => "A weekly brief",
        "commitments" => "Key 17 writes the brief",
        "name" => "Cascade Research",
        "symbol" => "CSR",
        "description" => "Research the fleet funds",
        "website" => "https://example.test",
        "image" => "ipfs://cascade",
        "required_regent_raised" => "250000.5"
      },
      attrs
    )
  end

  # The digest of `version` of plan `id`, as the workspace keeps it.
  defp digest(id, version) do
    [revision] =
      Graph.current_launch_plan_revisions!(@fleet, [%{object_id: id, version: version}])

    revision.digest
  end

  # Launch proposal `number` pointing to `digest`, its details read as
  # `envelope` says, and otherwise those of `plan_data/0`.
  defp launch!(number, digest, envelope \\ []) do
    @fleet
    |> ProposalHelpers.proposal!(number, kind: :autolaunch, digest: digest)
    |> ProposalHelpers.launch_envelope!(
      Keyword.merge(
        [
          description: "Research the fleet funds",
          required_regent_raised: Decimal.new("250000500000000000000000")
        ],
        envelope
      )
    )
  end

  defp votes!(number, sides) do
    for {support, token_ids} <- sides,
        do: ProposalHelpers.vote!(@fleet, number, @voter, support, token_ids)
  end

  defp balance(asset, figures) do
    Map.merge(
      %{asset: asset, free_capital: 0, backed: 0},
      Map.new(figures)
    )
  end

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-proposal]")
    |> Enum.map(fn card ->
      [kind, status] =
        card |> LazyHTML.query(".proposals-kind span") |> Enum.map(&text/1)

      {card |> LazyHTML.attribute("data-proposal") |> hd(), kind, status}
    end)
  end

  defp votes(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#proposal-votes li")
    |> Enum.map(&text/1)
  end

  defp fields(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(fn field ->
      {field |> LazyHTML.query("dt") |> LazyHTML.text(),
       field |> LazyHTML.query("dd") |> LazyHTML.text()}
    end)
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Whether each of `buttons` sends `step` when pressed, and nothing stops a
  # press: never disabled, hidden, handled by the page itself or inside a form.
  defp pressable?(view, step, buttons) do
    Enum.all?(buttons, fn button ->
      has_element?(
        view,
        ~s|#{button}[data-onchain-step="#{step}"]:not([disabled]):not([aria-disabled]):not([hidden]):not([phx-click])|
      ) and not has_element?(view, "form #{button}")
    end)
  end

  defp votes_pressable?(view) do
    pressable?(view, "yes", ["#proposal-vote-yes"]) and
      pressable?(view, "no", ["#proposal-vote-no"]) and
      pressable?(view, "withdraw", ["#proposal-vote-withdraw"])
  end

  # The texts of the notes matching `selector` that aren't hidden.
  defp shown_notes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.reject(&(LazyHTML.attribute(&1, "hidden") != []))
    |> Enum.map(&text/1)
  end

  # Privy's active wallet, as the wallet hook of the group `panel` reports it.
  defp active!(view, panel, wallet) do
    view |> with_target(panel) |> render_hook("onchain_active_wallet", %{"address" => wallet})
    render_async(view)
  end

  defp options(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&{&1 |> LazyHTML.attribute("value") |> hd(), text(&1)})
  end

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:proposals:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

  # An amount's words, and the full address of its token, if it shows one.
  defp amount(view, selector) do
    node = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
    token = LazyHTML.query(node, ".proposals-token")

    {text(node),
     if(Enum.empty?(token), do: nil, else: token |> LazyHTML.attribute("title") |> hd())}
  end

  # Polls every tenth of a second, `tries` times.
  defp shows?(check, tries \\ 30) do
    Enum.any?(1..tries, fn _try ->
      check.() or
        (
          Process.sleep(100)
          false
        )
    end)
  end
end
